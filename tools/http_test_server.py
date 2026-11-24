#!/usr/bin/env python3
"""
Local HTTP test server for HttpDownloadCore (standard library only; runs on Windows, macOS and Linux).

    python http_test_server.py --port 8099

Then download  http://<your-pc-ip>:8099/file/<size-in-bytes>[?option&option...]  with iTorrent Enhanced.
The body is deterministic and position-dependent (4 KiB blocks holding their own block number), so any
reordered, duplicated, shifted or missing chunk changes the bytes.  GET /hash/<size>?seed=N returns the SHA-256
that a correct download must have.  GET /log shows what the server saw, GET /reset clears the log.

Options (query string on /file/<size>):
  ranges=0        no Range support (no Accept-Ranges, Range ignored)
  ignore_range=1  probe (bytes=0-0) gets 206 but real ranged requests get 200 + the whole body
  bad_range=1     ranged answers carry a wrong Content-Range (shifted by one byte)
  etag=V          ETag "V" (default v1);  lm=0 removes Last-Modified
  slow=N          limit to N bytes per second per connection
  drop_after=N    close the connection after N body bytes ...  drop_times=K (default 1) times
  fail=CODE       answer CODE instead of the file ...          times=K (default 1) times
  nolen=1         no Content-Length (body ends when the connection closes) -> unknown size
  head=405        answer HEAD with 405
  redirect=1      302 to the same URL with redirected=1 appended
  cd=NAME         Content-Disposition: attachment; filename="NAME"
  gzip=1          really gzip the body (Content-Encoding: gzip, no ranges, unknown real size)
  seed=N          different content
"""
import argparse, gzip, hashlib, http.server, json, socketserver, threading, time, urllib.parse

BLOCK = 4096
LOCK = threading.Lock()
LOG = []
COUNTERS = {}
STATE = {"active": 0, "max_active": 0}


def block(i):
    return (i & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "big") * (BLOCK // 8)


def gen(start, length, seed=0):
    out = bytearray()
    pos, end = start, start + length
    while pos < end:
        b, off = divmod(pos, BLOCK)
        take = min(BLOCK - off, end - pos)
        out += block(b ^ seed)[off:off + take]
        pos += take
    return bytes(out)


def expected_hash(size, seed=0):
    h = hashlib.sha256()
    pos = 0
    while pos < size:
        n = min(1 << 20, size - pos)
        h.update(gen(pos, n, seed))
        pos += n
    return h.hexdigest()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "HttpTestServer/1"

    def log_message(self, fmt, *args):
        pass

    def _json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self, head_only):
        url = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        parts = [p for p in url.path.split("/") if p]
        if parts == ["log"]:
            with LOCK:
                return self._json({"requests": LOG, "max_active": STATE["max_active"]})
        if parts == ["reset"]:
            with LOCK:
                LOG.clear(); COUNTERS.clear(); STATE["max_active"] = 0
            return self._json({"ok": True})
        if len(parts) == 2 and parts[0] == "hash":
            return self._json({"sha256": expected_hash(int(parts[1]), int(q.get("seed", 0)))})
        if len(parts) != 2 or parts[0] != "file":
            self.send_error(404); return

        size, seed = int(parts[1]), int(q.get("seed", 0))
        etag = '"%s"' % q.get("etag", "v1")
        lm = "Mon, 01 Jan 2024 00:00:00 GMT" if q.get("lm", "1") != "0" else None
        rng_header = self.headers.get("Range")
        key = (url.path, url.query)

        with LOCK:
            STATE["active"] += 1
            STATE["max_active"] = max(STATE["max_active"], STATE["active"])
            LOG.append({"method": self.command, "path": url.path, "range": rng_header,
                        "if_range": self.headers.get("If-Range"), "accept_encoding": self.headers.get("Accept-Encoding")})
            n = COUNTERS.get(key, 0)
            COUNTERS[key] = n + (0 if head_only else 1)
        try:
            self._serve(q, size, seed, etag, lm, rng_header, head_only, n, url)
        finally:
            with LOCK:
                STATE["active"] -= 1

    def _headers(self, code, extra, q, etag, lm):
        self.send_response(code)
        self.send_header("ETag", etag)
        if lm:
            self.send_header("Last-Modified", lm)
        if "cd" in q:
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % q["cd"])
        for k, v in extra.items():
            self.send_header(k, v)

    def _serve(self, q, size, seed, etag, lm, rng_header, head_only, n, url):
        if head_only and q.get("head"):
            self.send_response(int(q["head"])); self.send_header("Content-Length", "0"); self.end_headers(); return
        if q.get("redirect") == "1" and "redirected" not in q:
            sep = "&" if url.query else "?"
            self.send_response(302)
            self.send_header("Location", "%s%s%sredirected=1" % (url.path, ("?" + url.query) if url.query else "", "&" if url.query else "?"))
            self.send_header("Content-Length", "0"); self.end_headers(); return
        if "fail" in q and not head_only and n < int(q.get("times", 1)):
            self.send_response(int(q["fail"])); self.send_header("Content-Length", "0"); self.end_headers(); return

        if q.get("gzip") == "1":
            body = gzip.compress(gen(0, size, seed))
            self._headers(200, {"Content-Length": str(len(body))}, {k: v for k, v in q.items() if k != "gzip"}, etag, lm)
            self.send_header("Content-Encoding", "gzip")
            self.end_headers()
            if not head_only:
                self.wfile.write(body)
            return
        supports = q.get("ranges", "1") != "0"
        start, end, status = 0, size - 1, 200
        extra = {}
        if rng_header and supports and size > 0:
            probe = rng_header.strip() == "bytes=0-0"
            if q.get("ignore_range") == "1" and not probe:
                pass                                           # pretend the Range header was not there
            else:
                a, _, b = rng_header.strip()[6:].partition("-")
                lo = int(a)
                hi = int(b) if b else size - 1
                if lo >= size:
                    self.send_response(416); self.send_header("Content-Range", "bytes */%d" % size)
                    self.send_header("Content-Length", "0"); self.end_headers(); return
                hi = min(hi, size - 1)
                ir = self.headers.get("If-Range")
                if ir and ir != etag and ir != lm:
                    pass                                       # validator mismatch: whole new representation, 200
                else:
                    start, end, status = lo, hi, 206
                    shown_lo, shown_hi = (lo + 1, hi + 1) if (q.get("bad_range") == "1" and not probe) else (lo, hi)
                    extra["Content-Range"] = "bytes %d-%d/%d" % (shown_lo, shown_hi, size)
        length = end - start + 1 if size > 0 else 0
        if supports:
            extra["Accept-Ranges"] = "bytes"
        nolen = q.get("nolen") == "1"
        if not nolen:
            extra["Content-Length"] = str(length)
        else:
            extra["Connection"] = "close"; self.close_connection = True
        self._headers(status, extra, q, etag, lm)
        self.end_headers()
        if head_only:
            return
        drop_after = int(q["drop_after"]) if "drop_after" in q and n < int(q.get("drop_times", 1)) else None
        slow = int(q.get("slow", 0))
        sent, pos = 0, start
        try:
            while sent < length:
                n_bytes = min(64 * 1024, length - sent)
                if drop_after is not None and sent + n_bytes > drop_after:
                    n_bytes = max(0, drop_after - sent)
                if n_bytes:
                    self.wfile.write(gen(pos, n_bytes, seed)); self.wfile.flush()
                    pos += n_bytes; sent += n_bytes
                if drop_after is not None and sent >= drop_after:
                    self.close_connection = True
                    return                                      # connection closes mid-body
                if slow:
                    time.sleep(n_bytes / float(slow))
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self): self._handle(False)
    def do_HEAD(self): self._handle(True)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8099)
    a = ap.parse_args()
    srv = Server((a.host, a.port), Handler)
    print("Listening on http://%s:%d  (try /file/10485760)" % (a.host, a.port), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
