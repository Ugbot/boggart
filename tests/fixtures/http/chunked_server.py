# A local HTTP server for tests/http_body.lua: binds an ephemeral port, prints
# it, serves GET /big as a 3 MiB body written in many small chunks, then exits
# after one request.
import http.server, socketserver, sys

BODY = b"".join(b"%07d:" % i + b"x" * 56 + b"\n" for i in range(48 * 1024))  # 3 MiB, line-numbered

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        for i in range(0, len(BODY), 4096):
            self.wfile.write(BODY[i:i + 4096])
            self.wfile.flush()

with socketserver.TCPServer(("127.0.0.1", 0), H) as s:
    print(s.server_address[1], flush=True)
    s.handle_request()
