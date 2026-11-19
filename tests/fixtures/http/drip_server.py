# A local HTTP server for tests/stream_timeouts.lua: binds an ephemeral port,
# prints it, serves one request, then exits.
#   GET /drip?n=N&gap=S    200, then N bytes, one every S seconds
#   GET /silent?s=S        says nothing for S seconds, then 200 and "late"
import http.server, socketserver, time, urllib.parse

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = {k: float(v[0]) for k, v in urllib.parse.parse_qs(u.query).items()}
        try:
            if u.path == "/drip":
                self.send_response(200)
                self.send_header("Content-Length", str(int(q["n"])))
                self.end_headers()
                for _ in range(int(q["n"])):
                    self.wfile.write(b"x"); self.wfile.flush()
                    time.sleep(q["gap"])
            else:
                time.sleep(q["s"])
                self.send_response(200)
                self.send_header("Content-Length", "4")
                self.end_headers()
                self.wfile.write(b"late")
        except (BrokenPipeError, ConnectionResetError):
            pass

with socketserver.TCPServer(("127.0.0.1", 0), H) as s:
    print(s.server_address[1], flush=True)
    s.handle_request()
