/* lserve.c -- the inbound control surface: a loopback HTTP/1.1 + SSE listener on
 * the libuv loop, exposed to Lua as the global `serve`.
 *
 * WHY THIS IS IN C, AND WHY ONLY THIS MUCH OF IT.
 *
 * Everything boggart could reach was OUTBOUND: libcurl to a model endpoint, a
 * subprocess, an MCP stdio pipe. There was no way for the world to reach IN --
 * no webhook, no remote control, no second client attaching to a running agent,
 * no "the agent is a service you can talk to". That is the missing half of the
 * control surface, and it is missing in C because Lua has no sockets: you
 * cannot open a listening TCP port from the harness, at any level of
 * self-modification, so no amount of rewriting the Lua overlay can add it.
 *
 * So this file holds exactly the two things Lua cannot do or must not be able
 * to undo, and NOTHING else:
 *
 *   1. TRANSPORT -- uv_tcp accept/read/write, HTTP/1.1 request framing, and the
 *      SSE keep-alive pump. Sockets and byte framing are the syscall layer.
 *
 *   2. ENFORCEMENT -- the two rules that must not be negotiable by the very Lua
 *      the agent rewrites:
 *        - it binds LOOPBACK unless someone explicitly asked otherwise, and a
 *          non-loopback bind without a token is REFUSED here, in C, not warned
 *          about in Lua;
 *        - the bearer token is compared in constant time, and request/header
 *          sizes are capped, so a hostile caller cannot exhaust memory.
 *      This is the same principle the rest of the core already follows -- the
 *      way sys.rmtree refuses "/" and proc.run bounds its output -- policy
 *      co-located with the capability, in the one place there is no second
 *      route around.
 *
 * Everything ELSE is Lua, deliberately: which routes exist, what they return,
 * what they are allowed to touch, who may call them, how events are shaped.
 * C hands the parsed request to ONE Lua callback and writes back whatever it
 * answers. Routing is the part that should change every week (lua/serve.lua),
 * so routing must not be in here. A control plane whose endpoints were compiled
 * in would be a different project's design.
 *
 *   serve.listen{ host=, port=, token=, handler=function(req) ... end } -> srv
 *   srv:port()                  the bound port (0 asks the OS to choose)
 *   srv:broadcast(event, data)  push one SSE frame to every attached stream
 *   srv:clients()               how many streams are attached
 *   srv:stop()
 *   serve.token(n)              n bytes of real entropy, hex (uv_random)
 *
 * The handler is called as handler(req) and returns either
 *   status:number, body:string, headers:table   -- an ordinary response
 * or the string "stream"                        -- keep it open as SSE
 */
#include <lua.h>
#include <lauxlib.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <uv.h>

extern uv_loop_t *luv_loop(lua_State *L);

/* Caps. A control plane is reachable by anything that can open a socket to it,
 * so the limits are the first line of defence and belong next to the parser. */
#define MAX_HEADER_BYTES (64 * 1024)
#define MAX_BODY_BYTES   (8 * 1024 * 1024)
#define MAX_CONNS        256

typedef struct Conn Conn;
typedef struct Server Server;

struct Conn {
  uv_tcp_t   tcp;
  Server    *srv;
  char      *buf;        /* accumulated request bytes */
  size_t     len, cap;
  int        is_stream;  /* upgraded to SSE: kept open, fed by broadcast */
  int        closing;
  Conn      *next;       /* server's connection list */
};

struct Server {
  uv_tcp_t   tcp;
  lua_State *L;
  int        handler_ref;
  char      *token;      /* NULL = no auth (loopback only) */
  size_t     token_len;
  int        nconns;
  Conn      *conns;
  int        stopped;
};

#define SERVER_MT "boggart.serve.server"

/* ---- small helpers -------------------------------------------------------- */

static void *xrealloc(void *p, size_t n) {
  void *q = realloc(p, n);
  if (!q) { free(p); }
  return q;
}

/* Constant-time compare: a token check that leaks its answer through timing is
 * not a token check. */
static int ct_equal(const char *a, size_t alen, const char *b, size_t blen) {
  if (alen != blen) return 0;
  unsigned char d = 0;
  for (size_t i = 0; i < alen; i++) d |= (unsigned char)(a[i] ^ b[i]);
  return d == 0;
}

static int conn_append(Conn *c, const char *data, size_t n) {
  if (c->len + n > MAX_HEADER_BYTES + MAX_BODY_BYTES) return -1;
  if (c->len + n + 1 > c->cap) {
    size_t want = c->cap ? c->cap : 4096;
    while (want < c->len + n + 1) want *= 2;
    c->buf = xrealloc(c->buf, want);
    if (!c->buf) { c->cap = c->len = 0; return -1; }
    c->cap = want;
  }
  memcpy(c->buf + c->len, data, n);
  c->len += n;
  c->buf[c->len] = 0;
  return 0;
}

static void unlink_conn(Server *s, Conn *c) {
  Conn **pp = &s->conns;
  while (*pp) {
    if (*pp == c) { *pp = c->next; s->nconns--; return; }
    pp = &(*pp)->next;
  }
}

static void on_conn_closed(uv_handle_t *h) {
  Conn *c = (Conn *)h->data;
  if (!c) return;
  if (c->srv) unlink_conn(c->srv, c);
  free(c->buf);
  free(c);
}

static void conn_close(Conn *c) {
  if (c->closing) return;
  c->closing = 1;
  uv_read_stop((uv_stream_t *)&c->tcp);
  if (!uv_is_closing((uv_handle_t *)&c->tcp)) {
    uv_close((uv_handle_t *)&c->tcp, on_conn_closed);
  }
}

/* ---- writing -------------------------------------------------------------- */

typedef struct { uv_write_t req; char *data; } WriteReq;

static void on_write(uv_write_t *req, int status) {
  WriteReq *w = (WriteReq *)req;
  Conn *c = (Conn *)req->data;
  free(w->data);
  free(w);
  if (status < 0 && c && !c->is_stream) conn_close(c);
}

static int conn_write(Conn *c, char *owned, size_t n) {
  if (c->closing) { free(owned); return -1; }
  WriteReq *w = calloc(1, sizeof(*w));
  if (!w) { free(owned); return -1; }
  w->data = owned;
  w->req.data = c;
  uv_buf_t b = uv_buf_init(owned, (unsigned int)n);
  int r = uv_write(&w->req, (uv_stream_t *)&c->tcp, &b, 1, on_write);
  if (r != 0) { free(owned); free(w); return -1; }
  return 0;
}

static void respond(Conn *c, int status, const char *ctype,
                    const char *body, size_t blen, const char *extra) {
  const char *reason = status == 200 ? "OK"
                     : status == 201 ? "Created"
                     : status == 204 ? "No Content"
                     : status == 400 ? "Bad Request"
                     : status == 401 ? "Unauthorized"
                     : status == 403 ? "Forbidden"
                     : status == 404 ? "Not Found"
                     : status == 413 ? "Payload Too Large"
                     : status == 500 ? "Internal Server Error"
                     : "OK";
  size_t cap = 512 + (extra ? strlen(extra) : 0) + blen;
  char *out = malloc(cap);
  if (!out) { conn_close(c); return; }
  int n = snprintf(out, cap,
    "HTTP/1.1 %d %s\r\n"
    "Content-Type: %s\r\n"
    "Content-Length: %zu\r\n"
    "Connection: close\r\n"
    "%s"
    "\r\n", status, reason, ctype ? ctype : "text/plain; charset=utf-8",
    blen, extra ? extra : "");
  if (n < 0 || (size_t)n >= cap) { free(out); conn_close(c); return; }
  if (blen) memcpy(out + n, body, blen);
  conn_write(c, out, (size_t)n + blen);
  /* Connection: close -- shut down once the write drains. The stream case
   * never reaches here; it goes through respond_stream. */
  if (!c->is_stream) {
    uv_shutdown_t *sd = calloc(1, sizeof(*sd));
    if (sd) {
      sd->data = c;
      uv_shutdown(sd, (uv_stream_t *)&c->tcp, NULL);
    }
  }
}

/* Upgrade this connection to an event stream and keep it. */
static void respond_stream(Conn *c) {
  static const char hdr[] =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: text/event-stream\r\n"
    "Cache-Control: no-store\r\n"
    "Connection: keep-alive\r\n"
    "\r\n"
    ": boggart control stream\n\n";
  size_t n = sizeof(hdr) - 1;
  char *copy = malloc(n);
  if (!copy) { conn_close(c); return; }
  memcpy(copy, hdr, n);
  c->is_stream = 1;
  conn_write(c, copy, n);
}

/* ---- request parsing ------------------------------------------------------ */
/*
 * Deliberately a subset: request line, headers, Content-Length body. No
 * chunked request bodies, no pipelining, no keep-alive for ordinary responses.
 * A local control plane does not need them, and every feature parsed here is a
 * feature that can be malformed at us.
 */
typedef struct {
  char *method, *path, *query, *body;
  size_t body_len;
  char *auth;         /* the Authorization header value, or NULL */
  int   headers_start;
} Req;

static char *dup_range(const char *a, const char *b) {
  size_t n = (size_t)(b - a);
  char *s = malloc(n + 1);
  if (!s) return NULL;
  memcpy(s, a, n);
  s[n] = 0;
  return s;
}

static void trim_lead(const char **p) { while (**p == ' ' || **p == '\t') (*p)++; }

/* Returns 1 when a whole request is present, 0 when more bytes are needed,
 * -1 on a malformed or oversized request. */
static int parse_request(Conn *c, Req *out, size_t *consumed) {
  memset(out, 0, sizeof(*out));
  const char *buf = c->buf;
  if (!buf) return 0;
  const char *hdr_end = strstr(buf, "\r\n\r\n");
  if (!hdr_end) {
    return c->len > MAX_HEADER_BYTES ? -1 : 0;
  }
  const char *line_end = strstr(buf, "\r\n");
  if (!line_end || line_end > hdr_end) return -1;

  /* request line: METHOD SP PATH SP HTTP/1.x */
  const char *sp1 = memchr(buf, ' ', (size_t)(line_end - buf));
  if (!sp1) return -1;
  const char *sp2 = memchr(sp1 + 1, ' ', (size_t)(line_end - sp1 - 1));
  if (!sp2) return -1;
  out->method = dup_range(buf, sp1);
  const char *q = memchr(sp1 + 1, '?', (size_t)(sp2 - sp1 - 1));
  if (q) {
    out->path = dup_range(sp1 + 1, q);
    out->query = dup_range(q + 1, sp2);
  } else {
    out->path = dup_range(sp1 + 1, sp2);
  }
  if (!out->method || !out->path) return -1;

  /* headers we care about: Content-Length and Authorization */
  size_t content_len = 0;
  const char *p = line_end + 2;
  while (p < hdr_end) {
    const char *eol = strstr(p, "\r\n");
    if (!eol || eol > hdr_end) break;
    const char *colon = memchr(p, ':', (size_t)(eol - p));
    if (colon) {
      size_t nlen = (size_t)(colon - p);
      const char *v = colon + 1;
      trim_lead(&v);
      if (nlen == 14 && strncasecmp(p, "content-length", 14) == 0) {
        content_len = (size_t)strtoul(v, NULL, 10);
        if (content_len > MAX_BODY_BYTES) return -1;
      } else if (nlen == 13 && strncasecmp(p, "authorization", 13) == 0) {
        free(out->auth);
        out->auth = dup_range(v, eol);
      }
    }
    p = eol + 2;
  }

  size_t head_bytes = (size_t)(hdr_end - buf) + 4;
  if (c->len < head_bytes + content_len) return 0;   /* body still arriving */
  if (content_len) {
    out->body = dup_range(buf + head_bytes, buf + head_bytes + content_len);
    out->body_len = content_len;
  }
  *consumed = head_bytes + content_len;
  return 1;
}

static void req_free(Req *r) {
  free(r->method); free(r->path); free(r->query); free(r->body); free(r->auth);
  memset(r, 0, sizeof(*r));
}

/* ---- dispatch into Lua ---------------------------------------------------- */

static void push_request(lua_State *L, Conn *c, Req *r) {
  lua_newtable(L);
  lua_pushstring(L, r->method ? r->method : "GET"); lua_setfield(L, -2, "method");
  lua_pushstring(L, r->path ? r->path : "/");       lua_setfield(L, -2, "path");
  if (r->query) { lua_pushstring(L, r->query); lua_setfield(L, -2, "query"); }
  if (r->body)  { lua_pushlstring(L, r->body, r->body_len); lua_setfield(L, -2, "body"); }

  /* the peer, so a Lua policy can tell a loopback caller from any other */
  struct sockaddr_storage ss;
  int nlen = (int)sizeof(ss);
  char ip[INET6_ADDRSTRLEN] = {0};
  if (uv_tcp_getpeername(&c->tcp, (struct sockaddr *)&ss, &nlen) == 0) {
    if (ss.ss_family == AF_INET) {
      uv_ip4_name((struct sockaddr_in *)&ss, ip, sizeof(ip));
    } else if (ss.ss_family == AF_INET6) {
      uv_ip6_name((struct sockaddr_in6 *)&ss, ip, sizeof(ip));
    }
    lua_pushstring(L, ip);
    lua_setfield(L, -2, "remote");
  }
}

static void handle_request(Conn *c, Req *r) {
  Server *s = c->srv;
  lua_State *L = s->L;

  /* AUTH, in C. When a token is configured every request must carry it; this
   * is checked before the handler is reached, so no Lua route can forget to. */
  if (s->token) {
    const char *got = r->auth;
    const char *bearer = NULL;
    if (got) {
      if (strncasecmp(got, "bearer ", 7) == 0) bearer = got + 7;
      else bearer = got;
    }
    if (!bearer || !ct_equal(bearer, strlen(bearer), s->token, s->token_len)) {
      respond(c, 401, "text/plain; charset=utf-8", "unauthorized\n", 13, NULL);
      return;
    }
  }

  int top = lua_gettop(L);
  lua_rawgeti(L, LUA_REGISTRYINDEX, s->handler_ref);
  if (!lua_isfunction(L, -1)) {
    lua_settop(L, top);
    respond(c, 500, "text/plain; charset=utf-8", "no handler\n", 11, NULL);
    return;
  }
  push_request(L, c, r);
  if (lua_pcall(L, 1, 3, 0) != LUA_OK) {
    const char *err = lua_tostring(L, -1);
    char msg[512];
    int n = snprintf(msg, sizeof(msg), "handler error: %s\n", err ? err : "?");
    lua_settop(L, top);
    respond(c, 500, "text/plain; charset=utf-8", msg, (size_t)(n > 0 ? n : 0), NULL);
    return;
  }

  /* handler -> "stream", or (status, body, headers) */
  if (lua_type(L, -3) == LUA_TSTRING && strcmp(lua_tostring(L, -3), "stream") == 0) {
    lua_settop(L, top);
    respond_stream(c);
    return;
  }
  int status = (int)luaL_optinteger(L, -3, 200);
  size_t blen = 0;
  const char *body = lua_isstring(L, -2) ? lua_tolstring(L, -2, &blen) : "";
  const char *ctype = "application/json";
  char extra[512] = {0};
  if (lua_istable(L, -1)) {
    lua_getfield(L, -1, "content_type");
    if (lua_isstring(L, -1)) ctype = lua_tostring(L, -1);
    lua_pop(L, 1);
  }
  /* copy the body out before settop lets Lua collect it */
  char *bcopy = malloc(blen ? blen : 1);
  if (bcopy && blen) memcpy(bcopy, body, blen);
  char ctbuf[128];
  snprintf(ctbuf, sizeof(ctbuf), "%s", ctype);
  lua_settop(L, top);
  respond(c, status, ctbuf, bcopy ? bcopy : "", blen, extra[0] ? extra : NULL);
  free(bcopy);
}

/* ---- reading -------------------------------------------------------------- */

static void alloc_cb(uv_handle_t *h, size_t suggested, uv_buf_t *buf) {
  (void)h;
  buf->base = malloc(suggested);
  buf->len = buf->base ? suggested : 0;
}

static void on_read(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf) {
  Conn *c = (Conn *)stream->data;
  if (nread < 0) {
    free(buf->base);
    conn_close(c);
    return;
  }
  if (nread > 0) {
    if (conn_append(c, buf->base, (size_t)nread) != 0) {
      free(buf->base);
      respond(c, 413, "text/plain; charset=utf-8", "too large\n", 10, NULL);
      return;
    }
  }
  free(buf->base);

  Req r;
  size_t consumed = 0;
  int st = parse_request(c, &r, &consumed);
  if (st < 0) {
    req_free(&r);
    respond(c, 400, "text/plain; charset=utf-8", "bad request\n", 12, NULL);
    return;
  }
  if (st == 0) return;              /* need more bytes */
  /* one request per connection: drop what was consumed and stop reading */
  uv_read_stop(stream);
  c->len = 0;
  if (c->buf) c->buf[0] = 0;
  handle_request(c, &r);
  req_free(&r);
}

static void on_connection(uv_stream_t *server, int status) {
  Server *s = (Server *)server->data;
  if (status != 0 || s->stopped) return;
  if (s->nconns >= MAX_CONNS) {
    /* Accept and immediately drop, so the backlog does not wedge. */
    uv_tcp_t tmp;
    uv_tcp_init(server->loop, &tmp);
    if (uv_accept(server, (uv_stream_t *)&tmp) == 0) {
      uv_close((uv_handle_t *)&tmp, NULL);
    }
    return;
  }
  Conn *c = calloc(1, sizeof(*c));
  if (!c) return;
  c->srv = s;
  if (uv_tcp_init(server->loop, &c->tcp) != 0) { free(c); return; }
  c->tcp.data = c;
  if (uv_accept(server, (uv_stream_t *)&c->tcp) != 0) {
    uv_close((uv_handle_t *)&c->tcp, on_conn_closed);
    return;
  }
  c->next = s->conns;
  s->conns = c;
  s->nconns++;
  uv_read_start((uv_stream_t *)&c->tcp, alloc_cb, on_read);
}

/* ---- Lua surface ---------------------------------------------------------- */

static Server *check_server(lua_State *L, int idx) {
  return (Server *)luaL_checkudata(L, idx, SERVER_MT);
}

static int l_listen(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);

  lua_getfield(L, 1, "host");
  const char *host = luaL_optstring(L, -1, "127.0.0.1");
  char hostbuf[128];
  snprintf(hostbuf, sizeof(hostbuf), "%s", host);
  lua_pop(L, 1);

  lua_getfield(L, 1, "port");
  int port = (int)luaL_optinteger(L, -1, 0);
  lua_pop(L, 1);

  lua_getfield(L, 1, "token");
  const char *token = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;
  char tokbuf[256] = {0};
  if (token) snprintf(tokbuf, sizeof(tokbuf), "%s", token);
  lua_pop(L, 1);

  /* THE ENFORCEMENT. Binding somewhere the network can reach is a different
   * act from binding loopback, and it is refused outright without a token --
   * in C, where the Lua the agent rewrites cannot decide otherwise. */
  int loopback = (strcmp(hostbuf, "127.0.0.1") == 0 || strcmp(hostbuf, "::1") == 0
                  || strcmp(hostbuf, "localhost") == 0);
  if (!loopback && tokbuf[0] == 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "refusing to bind %s without a token: a control plane "
                       "reachable off this machine must be authenticated", hostbuf);
    return 2;
  }

  lua_getfield(L, 1, "handler");
  if (!lua_isfunction(L, -1)) {
    lua_pop(L, 1);
    return luaL_error(L, "serve.listen: handler must be a function");
  }
  int handler_ref = luaL_ref(L, LUA_REGISTRYINDEX);

  /* the loop, materialised the same way every other module does it */
  lua_getglobal(L, "require");
  lua_pushliteral(L, "uv");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    lua_pop(L, 1);
    luaL_unref(L, LUA_REGISTRYINDEX, handler_ref);
    return luaL_error(L, "serve.listen: no uv loop");
  }
  lua_pop(L, 1);
  uv_loop_t *loop = luv_loop(L);
  if (!loop) {
    luaL_unref(L, LUA_REGISTRYINDEX, handler_ref);
    return luaL_error(L, "serve.listen: no uv loop");
  }

  Server *s = (Server *)lua_newuserdatauv(L, sizeof(Server), 0);
  memset(s, 0, sizeof(*s));
  s->L = L;
  s->handler_ref = handler_ref;
  if (tokbuf[0]) {
    s->token_len = strlen(tokbuf);
    s->token = malloc(s->token_len + 1);
    if (s->token) memcpy(s->token, tokbuf, s->token_len + 1);
  }
  luaL_getmetatable(L, SERVER_MT);
  lua_setmetatable(L, -2);

  if (uv_tcp_init(loop, &s->tcp) != 0) {
    lua_pushnil(L); lua_pushliteral(L, "tcp init failed"); return 2;
  }
  s->tcp.data = s;

  struct sockaddr_storage addr;
  const char *bind_host = strcmp(hostbuf, "localhost") == 0 ? "127.0.0.1" : hostbuf;
  int rc = uv_ip4_addr(bind_host, port, (struct sockaddr_in *)&addr);
  if (rc != 0) rc = uv_ip6_addr(bind_host, port, (struct sockaddr_in6 *)&addr);
  if (rc != 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "bad address %s", bind_host);
    return 2;
  }
  if ((rc = uv_tcp_bind(&s->tcp, (const struct sockaddr *)&addr, 0)) != 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "bind %s:%d failed: %s", bind_host, port, uv_strerror(rc));
    return 2;
  }
  if ((rc = uv_listen((uv_stream_t *)&s->tcp, 64, on_connection)) != 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "listen failed: %s", uv_strerror(rc));
    return 2;
  }
  /* The listener must not by itself keep the process alive: a REPL that has
   * finished should still exit. Whatever wants the server up (serve mode)
   * holds the loop open on its own terms. */
  uv_unref((uv_handle_t *)&s->tcp);
  return 1;
}

static int l_port(lua_State *L) {
  Server *s = check_server(L, 1);
  struct sockaddr_storage ss;
  int nlen = (int)sizeof(ss);
  if (uv_tcp_getsockname(&s->tcp, (struct sockaddr *)&ss, &nlen) != 0) {
    lua_pushnil(L); return 1;
  }
  int port = 0;
  if (ss.ss_family == AF_INET) port = ntohs(((struct sockaddr_in *)&ss)->sin_port);
  else if (ss.ss_family == AF_INET6) port = ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
  lua_pushinteger(L, port);
  return 1;
}

/* One SSE frame to every attached stream. Returns how many got it. */
static int l_broadcast(lua_State *L) {
  Server *s = check_server(L, 1);
  const char *event = luaL_checkstring(L, 2);
  size_t dlen = 0;
  const char *data = luaL_optlstring(L, 3, "", &dlen);
  int sent = 0;
  for (Conn *c = s->conns; c; c = c->next) {
    if (!c->is_stream || c->closing) continue;
    size_t cap = dlen + strlen(event) + 32;
    char *frame = malloc(cap);
    if (!frame) continue;
    int n = snprintf(frame, cap, "event: %s\ndata: ", event);
    if (n < 0 || (size_t)n + dlen + 2 > cap) { free(frame); continue; }
    memcpy(frame + n, data, dlen);
    frame[n + dlen] = '\n';
    frame[n + dlen + 1] = '\n';
    if (conn_write(c, frame, (size_t)n + dlen + 2) == 0) sent++;
  }
  lua_pushinteger(L, sent);
  return 1;
}

static int l_clients(lua_State *L) {
  Server *s = check_server(L, 1);
  int n = 0;
  for (Conn *c = s->conns; c; c = c->next) if (c->is_stream && !c->closing) n++;
  lua_pushinteger(L, n);
  return 1;
}

static void on_server_closed(uv_handle_t *h) { (void)h; }

static int l_stop(lua_State *L) {
  Server *s = check_server(L, 1);
  if (s->stopped) { lua_pushboolean(L, 0); return 1; }
  s->stopped = 1;
  Conn *c = s->conns;
  while (c) { Conn *next = c->next; conn_close(c); c = next; }
  if (!uv_is_closing((uv_handle_t *)&s->tcp)) {
    uv_close((uv_handle_t *)&s->tcp, on_server_closed);
  }
  if (s->handler_ref != LUA_NOREF) {
    luaL_unref(L, LUA_REGISTRYINDEX, s->handler_ref);
    s->handler_ref = LUA_NOREF;
  }
  free(s->token);
  s->token = NULL;
  lua_pushboolean(L, 1);
  return 1;
}

static int l_gc(lua_State *L) {
  Server *s = (Server *)luaL_testudata(L, 1, SERVER_MT);
  if (s && !s->stopped) {
    s->stopped = 1;
    Conn *c = s->conns;
    while (c) { Conn *next = c->next; conn_close(c); c = next; }
    if (!uv_is_closing((uv_handle_t *)&s->tcp)) {
      uv_close((uv_handle_t *)&s->tcp, on_server_closed);
    }
    free(s->token);
    s->token = NULL;
  }
  return 0;
}

/* Real entropy, hex-encoded. In C because a CSPRNG is a syscall (uv_random),
 * and a control-plane token generated from Lua's math.random would be
 * guessable -- the one property it exists to have. */
static int l_token(lua_State *L) {
  int n = (int)luaL_optinteger(L, 1, 24);
  if (n < 8) n = 8;
  if (n > 64) n = 64;
  unsigned char raw[64];
  if (uv_random(NULL, NULL, raw, (size_t)n, 0, NULL) != 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "no entropy source");
    return 2;
  }
  char hex[129];
  static const char *H = "0123456789abcdef";
  for (int i = 0; i < n; i++) {
    hex[i * 2]     = H[raw[i] >> 4];
    hex[i * 2 + 1] = H[raw[i] & 0xf];
  }
  lua_pushlstring(L, hex, (size_t)n * 2);
  return 1;
}

static const luaL_Reg server_methods[] = {
  { "port",      l_port },
  { "broadcast", l_broadcast },
  { "clients",   l_clients },
  { "stop",      l_stop },
  { NULL, NULL }
};

static const luaL_Reg serve_lib[] = {
  { "listen", l_listen },
  { "token",  l_token },
  { NULL, NULL }
};

int luaopen_boggart_serve(lua_State *L);
int luaopen_boggart_serve(lua_State *L) {
  luaL_newmetatable(L, SERVER_MT);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  luaL_setfuncs(L, server_methods, 0);
  lua_pushcfunction(L, l_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);

  luaL_newlib(L, serve_lib);
  return 1;
}
