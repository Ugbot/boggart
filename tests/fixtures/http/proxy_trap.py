# A proxy that forwards nothing, for tests that must prove a run stayed on the
# machine (tests/route_override.lua). Point HTTPS_PROXY / HTTP_PROXY at it with
# NO_PROXY covering 127.0.0.1: any request bound for another host then arrives
# here instead of leaving -- as "CONNECT host:443" for https -- and is logged
# to the file named by argv[1] (one request line per line) and refused.
#
# Binds an ephemeral port and prints it. A GET /quit stops it; exits on its own
# after argv[2] seconds in case the test died before asking.
import socketserver, sys, threading

OUT = sys.argv[1]
LIFE = float(sys.argv[2]) if len(sys.argv) > 2 else 30
LOCK = threading.Lock()

class H(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline(4096).decode("latin-1").strip()
        if line.startswith("GET /quit"):
            threading.Thread(target=self.server.shutdown).start()
        elif line:
            with LOCK:
                with open(OUT, "a") as f:
                    f.write(line + "\n")
        self.wfile.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

class S(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True

with S(("127.0.0.1", 0), H) as s:
    print(s.server_address[1], flush=True)
    timer = threading.Timer(LIFE, s.shutdown)
    timer.daemon = True
    timer.start()
    s.serve_forever()
