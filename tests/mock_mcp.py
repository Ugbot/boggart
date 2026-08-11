#!/usr/bin/env python3
# Minimal MCP stdio server for testing boggart's C MCP client.
# Speaks newline-delimited JSON-RPC over stdin/stdout: initialize, tools/list,
# tools/call (echo, add). Logs go to stderr (ignored by the client).
import sys, json


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


TOOLS = [
    {"name": "echo", "description": "Echo the given text.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
    {"name": "add", "description": "Add two numbers a and b.",
     "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
                     "required": ["a", "b"]}},
]


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception as e:
            sys.stderr.write("mock: bad json: %s\n" % e)
            continue
        method = msg.get("method")
        mid = msg.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": "2025-11-25",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "mock", "version": "0.1"}}})
        elif method == "notifications/initialized":
            pass  # notification: no response
        elif method == "tools/list":
            # Paginated, one tool per page. tools/list is cursor-paginated in
            # every revision of the spec, and the client used to read the first
            # page and discard nextCursor -- so a server with more tools than
            # one page had the rest silently dropped. Serving one per page here
            # means any regression shows up as a missing tool rather than as
            # nothing at all.
            cur = (msg.get("params") or {}).get("cursor")
            i = int(cur) if cur else 0
            result = {"tools": TOOLS[i:i + 1]}
            if i + 1 < len(TOOLS):
                result["nextCursor"] = str(i + 1)
            send({"jsonrpc": "2.0", "id": mid, "result": result})
        elif method == "tools/call":
            p = msg.get("params", {})
            name = p.get("name")
            args = p.get("arguments", {})
            if name == "echo":
                send({"jsonrpc": "2.0", "id": mid,
                      "result": {"content": [{"type": "text", "text": "echo: " + str(args.get("text", ""))}]}})
            elif name == "add":
                total = args.get("a", 0) + args.get("b", 0)
                send({"jsonrpc": "2.0", "id": mid,
                      "result": {"content": [{"type": "text", "text": str(total)}]}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown tool: %s" % name}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found"}})


if __name__ == "__main__":
    main()
