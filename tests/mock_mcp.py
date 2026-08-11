#!/usr/bin/env python3
# Minimal MCP stdio server for testing boggart's C MCP client. Speaks
# newline-delimited JSON-RPC over stdin/stdout.
#
# It can play either protocol generation, because the client has to negotiate
# between them and a test that only ever meets one of them proves nothing:
#
#   --era v1  (default)  the handshake generation (2025-11-25 and earlier):
#                        initialize + notifications/initialized, no resultType,
#                        and -32601 for server/discover, which is exactly what
#                        makes the client fall back.
#   --era v2             the stateless generation (2026-07-28): no handshake at
#                        all, server/discover for negotiation, required _meta on
#                        every request (rejected with -32602 when missing), and
#                        resultType on every result.
#
# and two v2 variations worth having tests for:
#
#   --input-required     tools/call answers with resultType "input_required"
#                        (the MRTR pattern). A client that hands that back as if
#                        it were the tool's answer is broken in a way nothing
#                        else notices, so the test needs a server that does it.
#   --supported V[,V]    what the server admits to speaking. Set it to something
#                        the client cannot speak and every request is met with
#                        UnsupportedProtocolVersion (-32022).
#
# --trace FILE appends every message received, one JSON object per line, so the
# tests can assert on what actually went over the wire rather than on what the
# client claims it did. Over HTTP the traced object also carries "_http": the
# request headers, which is where half the difference between the generations
# lives (Mcp-Method and Mcp-Name are required now; Mcp-Session-Id is gone).
#
# --http serves the same two generations over Streamable HTTP instead of stdio,
# on an ephemeral port written to --portfile.
import sys, json, argparse

MODERN = "2026-07-28"
LEGACY = "2025-11-25"

META_PROTO = "io.modelcontextprotocol/protocolVersion"
META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo"
META_CLIENT_CAPS = "io.modelcontextprotocol/clientCapabilities"
META_SERVER_INFO = "io.modelcontextprotocol/serverInfo"

SERVER_INFO = {"name": "mock", "version": "0.1"}

TOOLS = [
    {"name": "echo", "description": "Echo the given text.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
    {"name": "add", "description": "Add two numbers a and b.",
     "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
                     "required": ["a", "b"]}},
]

args = None
# Where send() puts its reply. None means stdout (the stdio transport); an HTTP
# request swaps in a list, so the handlers below stay transport-agnostic. Safe
# as a global only because this mock answers one request at a time.
OUT = None
SESSION = "mock-session-1"


def send(obj):
    if OUT is not None:
        OUT.append(obj)
        return
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def trace(msg, headers=None):
    if not args.trace:
        return
    rec = dict(msg)
    if headers is not None:
        rec["_http"] = headers
    with open(args.trace, "a") as fh:
        fh.write(json.dumps(rec) + "\n")
        fh.flush()


def ok(mid, result):
    # v2 results all carry resultType, and the server identifies itself in each
    # result's _meta because there is no handshake to have done it once.
    if args.era == "v2":
        result = dict(result)
        result.setdefault("resultType", "complete")
        result["_meta"] = {META_SERVER_INFO: SERVER_INFO}
    send({"jsonrpc": "2.0", "id": mid, "result": result})


def fail(mid, code, message, data=None):
    err = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    send({"jsonrpc": "2.0", "id": mid, "error": err})


def tools_page(msg):
    # Paginated, one tool per page. tools/list is cursor-paginated in every
    # revision of the spec, and the client used to read the first page and
    # discard nextCursor -- so a server with more tools than one page had the
    # rest silently dropped. Serving one per page here means any regression
    # shows up as a missing tool rather than as nothing at all.
    cur = (msg.get("params") or {}).get("cursor")
    i = int(cur) if cur else 0
    result = {"tools": TOOLS[i:i + 1]}
    if i + 1 < len(TOOLS):
        result["nextCursor"] = str(i + 1)
    return result


def tools_call(mid, msg):
    p = msg.get("params", {})
    name = p.get("name")
    a = p.get("arguments", {})
    if args.era == "v2" and args.input_required and name in ("echo", "add"):
        # The server wants something from the client before it can answer. The
        # interim result deliberately also carries a plausible-looking content
        # block: a client that ignores resultType will hand *this* to the model
        # and call it the tool's output.
        ok(mid, {
            "resultType": "input_required",
            "content": [{"type": "text", "text": "PREMATURE: this is not an answer"}],
            "inputRequests": {
                "who": {"method": "elicitation/create",
                        "params": {"mode": "form", "message": "Who are you?",
                                   "requestedSchema": {"type": "object",
                                                       "properties": {"name": {"type": "string"}},
                                                       "required": ["name"]}}},
            },
            "requestState": "opaque-blob",
        })
        return
    if name == "echo":
        ok(mid, {"content": [{"type": "text", "text": "echo: " + str(a.get("text", ""))}]})
    elif name == "add":
        ok(mid, {"content": [{"type": "text", "text": str(a.get("a", 0) + a.get("b", 0))}]})
    else:
        fail(mid, -32601, "unknown tool: %s" % name)


def version_of(msg):
    return ((msg.get("params") or {}).get("_meta") or {}).get(META_PROTO)


def handle_v1(msg, method, mid):
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": LEGACY,
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO}})
    elif method == "notifications/initialized":
        pass  # notification: no response
    elif method == "tools/list":
        ok(mid, tools_page(msg))
    elif method == "tools/call":
        tools_call(mid, msg)
    elif mid is not None:
        # server/discover lands here, which is the whole point: a legacy server
        # does not know the method and says so, and that is the client's cue to
        # run the handshake instead.
        fail(mid, -32601, "method not found")


def handle_v2(msg, method, mid):
    if method == "initialize":
        # A modern-only server SHOULD name the versions it speaks even to a
        # client that cannot act on the answer -- it may be the only diagnostic
        # a legacy client can show a user.
        fail(mid, -32601, "this server speaks %s only" % ", ".join(args.supported),
             {"supported": args.supported})
        return
    if mid is None:
        return  # notifications are not answered

    meta = (msg.get("params") or {}).get("_meta") or {}
    if META_PROTO not in meta or META_CLIENT_CAPS not in meta:
        fail(mid, -32602, "request is missing required _meta fields")
        return
    if meta[META_PROTO] not in args.supported:
        fail(mid, -32022, "Unsupported protocol version",
             {"supported": args.supported, "requested": meta[META_PROTO]})
        return

    if method == "server/discover":
        ok(mid, {"supportedVersions": args.supported,
                 "capabilities": {"tools": {}},
                 "instructions": "mock server, two tools",
                 "ttlMs": 3600000, "cacheScope": "public"})
    elif method == "tools/list":
        ok(mid, tools_page(msg))
    elif method == "tools/call":
        tools_call(mid, msg)
    else:
        fail(mid, -32601, "method not found")


def dispatch(msg):
    method, mid = msg.get("method"), msg.get("id")
    if args.era == "v1":
        handle_v1(msg, method, mid)
    else:
        handle_v2(msg, method, mid)


def serve_http():
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass  # keep the test output clean

        def do_POST(self):
            global OUT
            n = int(self.headers.get("content-length", 0))
            try:
                msg = json.loads(self.rfile.read(n))
            except Exception:
                self.send_response(400)
                self.send_header("content-length", "0")
                self.end_headers()
                return
            trace(msg, {k.lower(): v for k, v in self.headers.items()})
            OUT = []
            dispatch(msg)
            replies, OUT = OUT, None
            if not replies:
                self.send_response(202)  # a notification the server accepted
                self.send_header("content-length", "0")
                self.end_headers()
                return
            body = json.dumps(replies[0]).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            # A legacy server hands out a session on initialize and expects it
            # back. A modern one has no sessions at all.
            if args.era == "v1" and msg.get("method") == "initialize":
                self.send_header("mcp-session-id", SESSION)
            self.end_headers()
            self.wfile.write(body)

    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    if args.portfile:
        # The trailing newline is the "finished writing" marker the test waits
        # for: a reader that catches the file mid-write would otherwise parse a
        # truncated port number and connect somewhere else entirely.
        with open(args.portfile, "w") as fh:
            fh.write("%d\n" % srv.server_address[1])
    srv.serve_forever()


def main():
    global args
    ap = argparse.ArgumentParser()
    ap.add_argument("--era", choices=["v1", "v2"], default="v1")
    ap.add_argument("--supported", default=MODERN,
                    help="comma-separated protocol versions the v2 server admits to")
    ap.add_argument("--input-required", action="store_true")
    ap.add_argument("--trace")
    ap.add_argument("--http", action="store_true", help="serve Streamable HTTP instead of stdio")
    ap.add_argument("--portfile", help="where to write the port --http bound to")
    args = ap.parse_args()
    args.supported = [v for v in args.supported.split(",") if v]

    if args.http:
        serve_http()
        return

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception as e:
            sys.stderr.write("mock: bad json: %s\n" % e)
            continue
        trace(msg)
        dispatch(msg)


if __name__ == "__main__":
    main()
