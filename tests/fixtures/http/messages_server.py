# A stand-in Messages API for the end-to-end tests (tests/runflags.lua,
# tests/headless.lua): binds an ephemeral port, prints it, appends every
# POSTed request body (one JSON object per line) to the file named by argv[1],
# and answers each with a short streamed reply.
#
# argv[3], optional, names a JSON file holding a script: a list of replies,
# used one per POST in order. Each entry is one of
#   {"text": "..."}                                   a text reply, end_turn
#   {"tool_use": {"id": "...", "name": "...", "input": {...}}}
#                                                     a tool call, stop tool_use
#   {"hang": true}                                    never answer (the client
#                                                     is expected to be killed)
# Once the script runs out (or with no script) every POST gets the text "done".
#
# A GET /quit stops it; any other GET (a /props probe) is a 404. Exits on its
# own after argv[2] seconds in case the test died before asking.
import http.server, socketserver, sys, threading, json, time

OUT = sys.argv[1]
LIFE = float(sys.argv[2]) if len(sys.argv) > 2 else 30
SCRIPT = []
if len(sys.argv) > 3:
    with open(sys.argv[3]) as f:
        SCRIPT = json.load(f)
LOCK = threading.Lock()
STATE = {"n": 0}
STOP = threading.Event()

def sse(event, data):
    return ("event: %s\ndata: %s\n\n" % (event, json.dumps(data))).encode()

def text_reply(text):
    return b"".join([
        sse("message_start", {"type": "message_start", "message": {
            "id": "msg_test", "type": "message", "role": "assistant", "content": [],
            "usage": {"input_tokens": 100, "output_tokens": 0}}}),
        sse("content_block_start", {"type": "content_block_start", "index": 0,
                                    "content_block": {"type": "text", "text": ""}}),
        sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                                    "delta": {"type": "text_delta", "text": text}}),
        sse("content_block_stop", {"type": "content_block_stop", "index": 0}),
        sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
                              "usage": {"output_tokens": 1}}),
        sse("message_stop", {"type": "message_stop"}),
    ])

def tool_reply(call):
    return b"".join([
        sse("message_start", {"type": "message_start", "message": {
            "id": "msg_test", "type": "message", "role": "assistant", "content": [],
            "usage": {"input_tokens": 100, "output_tokens": 0}}}),
        sse("content_block_start", {"type": "content_block_start", "index": 0,
                                    "content_block": {"type": "tool_use", "id": call["id"],
                                                      "name": call["name"], "input": {}}}),
        sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                                    "delta": {"type": "input_json_delta",
                                              "partial_json": json.dumps(call.get("input", {}))}}),
        sse("content_block_stop", {"type": "content_block_stop", "index": 0}),
        sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use"},
                              "usage": {"output_tokens": 5}}),
        sse("message_stop", {"type": "message_stop"}),
    ])

REPLY = text_reply("done")

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/quit":
            STOP.set()
            threading.Thread(target=self.server.shutdown).start()
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        with LOCK:
            with open(OUT, "ab") as f:
                f.write(body.replace(b"\n", b" ") + b"\n")
            i = STATE["n"]
            STATE["n"] = i + 1
        step = SCRIPT[i] if i < len(SCRIPT) else None
        if step and step.get("hang"):
            STOP.wait(LIFE)
            return
        if step and "tool_use" in step:
            reply = tool_reply(step["tool_use"])
        elif step and "text" in step:
            reply = text_reply(step["text"])
        else:
            reply = REPLY
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)
        self.wfile.flush()

class S(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True

with S(("127.0.0.1", 0), H) as s:
    print(s.server_address[1], flush=True)
    timer = threading.Timer(LIFE, s.shutdown)
    timer.daemon = True   # /quit must end the process now, not when this fires
    timer.start()
    s.serve_forever()
