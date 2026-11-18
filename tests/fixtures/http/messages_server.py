# A stand-in Messages API for tests/runflags.lua: binds an ephemeral port,
# prints it, appends every POSTed request body (one JSON object per line) to
# the file named by argv[1], and answers each with a short streamed reply.
# A GET /quit stops it; any other GET (a /props probe) is a 404. Exits on its
# own after argv[2] seconds in case the test died before asking.
import http.server, socketserver, sys, threading, json

OUT = sys.argv[1]
LIFE = float(sys.argv[2]) if len(sys.argv) > 2 else 30

def sse(event, data):
    return ("event: %s\ndata: %s\n\n" % (event, json.dumps(data))).encode()

REPLY = b"".join([
    sse("message_start", {"type": "message_start", "message": {
        "id": "msg_test", "type": "message", "role": "assistant", "content": [],
        "usage": {"input_tokens": 100, "output_tokens": 0}}}),
    sse("content_block_start", {"type": "content_block_start", "index": 0,
                                "content_block": {"type": "text", "text": ""}}),
    sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                                "delta": {"type": "text_delta", "text": "done"}}),
    sse("content_block_stop", {"type": "content_block_stop", "index": 0}),
    sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
                          "usage": {"output_tokens": 1}}),
    sse("message_stop", {"type": "message_stop"}),
])

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/quit":
            threading.Thread(target=self.server.shutdown).start()
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        with open(OUT, "ab") as f:
            f.write(body.replace(b"\n", b" ") + b"\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(REPLY)))
        self.end_headers()
        self.wfile.write(REPLY)
        self.wfile.flush()

class S(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True

with S(("127.0.0.1", 0), H) as s:
    print(s.server_address[1], flush=True)
    threading.Timer(LIFE, s.shutdown).start()
    s.serve_forever()
