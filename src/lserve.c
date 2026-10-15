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
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <lua.h>
#include <lauxlib.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <uv.h>
#ifndef _WIN32
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#endif

extern uv_loop_t *luv_loop(lua_State *L);

/* Caps. A control plane is reachable by anything that can open a socket to it,
 * so the limits are the first line of defence and belong next to the parser. */
#define MAX_HEADER_BYTES (64 * 1024)
#define MAX_BODY_BYTES   (8 * 1024 * 1024)
#define MAX_CONNS        256
#define MAX_WRITE_QUEUE (8u * 1024u * 1024u)

typedef struct Conn Conn;
typedef struct Server Server;

struct Conn {
  union { uv_tcp_t tcp; uv_pipe_t pipe; } io;
  Server    *srv;
  char      *buf;        /* accumulated request bytes */
  size_t     len, cap;
  int        is_stream;  /* upgraded to SSE: kept open, fed by broadcast */
  char channel[129];     /* empty = global events; otherwise exact private tag */
  int        closing;
  Conn      *next;       /* server's connection list */
  size_t queued_bytes;
};

struct Server {
  union { uv_tcp_t tcp; uv_pipe_t pipe; } io;
  lua_State *L;
  int        handler_ref;
  char      *token;      /* NULL = no auth (loopback only) */
  size_t     token_len;
  char       host[128];
  int        nconns;
  Conn      *conns;
  int        stopped;
  int        unix_socket, initialized, released, handles;
  uv_loop_t *loop;
  Server *next;
  char socket_path[256];
  uint64_t socket_dev, socket_ino;
  size_t body_limit;
};
typedef struct { Server *native; } ServerOwner;
static _Thread_local Server *servers;
static char server_started,server_shutdown;
static uv_stream_t *server_stream(Server *s){return s->unix_socket ? (uv_stream_t *)&s->io.pipe : (uv_stream_t *)&s->io.tcp;}
static uv_stream_t *conn_stream(Conn *c){return c->srv->unix_socket ? (uv_stream_t *)&c->io.pipe : (uv_stream_t *)&c->io.tcp;}
static void server_free(Server *s) {
  if(!s->released || s->handles)return;
  Server **entry=&servers;while(*entry && *entry!=s)entry=&(*entry)->next;
  if(*entry)*entry=s->next;free(s);
}
static void unlink_socket(Server *s) {
#ifndef _WIN32
  struct stat info;
  if(s->socket_ino && !lstat(s->socket_path,&info) && S_ISSOCK(info.st_mode)
    && (uint64_t)info.st_dev==s->socket_dev && (uint64_t)info.st_ino==s->socket_ino)unlink(s->socket_path);
#endif
  s->socket_ino=0;
}

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
  if (n>MAX_HEADER_BYTES+c->srv->body_limit-c->len) return -1;
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
  Server *s=c->srv;
  if (s) unlink_conn(s,c);
  free(c->buf);
  free(c);
  if(s){s->handles--;server_free(s);}
}

static void conn_close(Conn *c) {
  if (c->closing) return;
  c->closing = 1;
  uv_read_stop(conn_stream(c));
  if (!uv_is_closing((uv_handle_t *)conn_stream(c))) {
    uv_close((uv_handle_t *)conn_stream(c), on_conn_closed);
  }
}

/* ---- writing -------------------------------------------------------------- */

typedef struct { uv_write_t req; char *data; size_t length; } WriteReq;

static void on_write(uv_write_t *req, int status) {
  WriteReq *w = (WriteReq *)req;
  Conn *c = (Conn *)req->data;
  if(c)c->queued_bytes-=w->length;
  free(w->data);
  free(w);
  if (status < 0 && c) conn_close(c);
}

static int conn_write(Conn *c, char *owned, size_t n) {
  if (c->closing) { free(owned); return -1; }
  if(n>MAX_WRITE_QUEUE-c->queued_bytes){free(owned);conn_close(c);return -1;}
  WriteReq *w = calloc(1, sizeof(*w));
  if (!w) { free(owned);conn_close(c);return -1; }
  w->data = owned;
  w->length=n;c->queued_bytes+=n;
  w->req.data = c;
  uv_buf_t b = uv_buf_init(owned, (unsigned int)n);
  int r = uv_write(&w->req,conn_stream(c),&b,1,on_write);
  if (r != 0) { c->queued_bytes-=n;free(owned);free(w);conn_close(c);return -1; }
  return 0;
}
static void on_shutdown(uv_shutdown_t *request,int status) {
  (void)status;Conn *c=request->data;free(request);conn_close(c);
}

static void respond(Conn *c, int status, const char *ctype,
                    const char *body, size_t blen, const char *extra) {
  uv_read_stop(conn_stream(c));
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
      if(uv_shutdown(sd,conn_stream(c),on_shutdown)){free(sd);conn_close(c);}
    } else {
      conn_close(c);
    }
  }
}

static void alloc_cb(uv_handle_t *h,size_t suggested,uv_buf_t *buf);
static void stream_read(uv_stream_t *stream,ssize_t nread,const uv_buf_t *buf) {
  Conn *c=stream->data;free(buf->base);
  if(nread!=0)conn_close(c); /* EOF or unexpected client input after upgrade. */
}
static int stream_write(Conn *c,const char *event,size_t event_length,const char *data,size_t length) {
  if(length>MAX_WRITE_QUEUE-256){conn_close(c);return -1;}
  size_t capacity=length+event_length+32;char *frame=malloc(capacity);
  if(!frame){conn_close(c);return -1;}
  int prefix=snprintf(frame,capacity,"event: %s\ndata: ",event);
  if(prefix<0 || (size_t)prefix+length+2>capacity){free(frame);conn_close(c);return -1;}
  memcpy(frame+prefix,data,length);frame[prefix+length]='\n';frame[prefix+length+1]='\n';
  return conn_write(c,frame,(size_t)prefix+length+2);
}
/* Upgrade only after Lua has authorized the exact channel and initial frame. */
static void respond_stream(Conn *c,const char *initial,size_t initial_length) {
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
  if(conn_write(c,copy,n))return;
  if(initial && stream_write(c,"message",7,initial,initial_length))return;
  if(uv_read_start(conn_stream(c),alloc_cb,stream_read))conn_close(c);
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
  char *host, *origin;
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
  if ((size_t)(hdr_end-buf)>MAX_HEADER_BYTES) return -1;
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

  /* Security-sensitive headers are singletons. Reject ambiguous framing,
   * folded/malformed fields and embedded NULs rather than normalizing them. */
  if (memchr(buf, 0, (size_t)(hdr_end-buf))) return -1;
  size_t content_len = 0;
  int seen_length = 0;
  const char *p = line_end + 2;
  while (p < hdr_end) {
    const char *eol = strstr(p, "\r\n");
    if (!eol || eol > hdr_end) return -1;
    const char *colon = memchr(p, ':', (size_t)(eol - p));
    if (!colon || colon==p) return -1;
    for (const char *k=p;k<colon;k++) {
      if (!((*k>='a' && *k<='z') || (*k>='A' && *k<='Z') ||
            (*k>='0' && *k<='9') || strchr("!#$%&'*+-.^_`|~",*k))) return -1;
    }
    size_t nlen = (size_t)(colon - p);
    const char *v = colon + 1, *end=eol;
    trim_lead(&v);
    while (end>v && (end[-1]==' ' || end[-1]=='\t')) end--;
    for (const char *k=v;k<end;k++) if ((unsigned char)*k<32 || *k==127) return -1;
    if (nlen == 14 && strncasecmp(p, "content-length", 14) == 0) {
      if (seen_length++ || v==end) return -1;
      for (const char *k=v;k<end;k++) {
        if (*k<'0' || *k>'9') return -1;
        content_len=content_len*10+(size_t)(*k-'0');
        if (content_len>c->srv->body_limit) return -1;
      }
    } else if (nlen==17 && strncasecmp(p,"transfer-encoding",17)==0) return -1;
    else {
      char **field=NULL;
      if (nlen==13 && strncasecmp(p,"authorization",13)==0) field=&out->auth;
      if (nlen==4 && strncasecmp(p,"host",4)==0) field=&out->host;
      if (nlen==6 && strncasecmp(p,"origin",6)==0) field=&out->origin;
      if (field) {
        if (*field || v==end) return -1;
        *field=dup_range(v,end);
        if (!*field) return -1;
      }
    }
    p=eol+2;
  }
  if (!out->host) return -1;

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
  free(r->method); free(r->path); free(r->query); free(r->body); free(r->auth); free(r->host); free(r->origin);
  memset(r, 0, sizeof(*r));
}

/* ---- dispatch into Lua ---------------------------------------------------- */

static void push_request(lua_State *L, Conn *c, Req *r) {
  lua_newtable(L);
  lua_pushboolean(L, 1); lua_setfield(L, -2, "authenticated");
  lua_pushstring(L, r->host); lua_setfield(L, -2, "host");
  if (r->origin) { lua_pushstring(L, r->origin); lua_setfield(L, -2, "origin"); }
  lua_pushstring(L, r->method ? r->method : "GET"); lua_setfield(L, -2, "method");
  lua_pushstring(L, r->path ? r->path : "/");       lua_setfield(L, -2, "path");
  if (r->query) { lua_pushstring(L, r->query); lua_setfield(L, -2, "query"); }
  if (r->body)  { lua_pushlstring(L, r->body, r->body_len); lua_setfield(L, -2, "body"); }

  /* the peer, so a Lua policy can tell a loopback caller from any other */
  struct sockaddr_storage ss;
  int nlen = (int)sizeof(ss);
  char ip[INET6_ADDRSTRLEN] = {0};
  if(c->srv->unix_socket){lua_pushliteral(L,"unix");lua_setfield(L,-2,"remote");}
  else if (uv_tcp_getpeername(&c->io.tcp, (struct sockaddr *)&ss, &nlen) == 0) {
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

  /* Compare the actual authority against this listener's bound host/port.
   * A browser Origin, when supplied, must be exactly this HTTP origin. */
  struct sockaddr_storage addr;
  int addrlen=sizeof(addr), port=0;
  if (!s->unix_socket && uv_tcp_getsockname(&s->io.tcp,(struct sockaddr *)&addr,&addrlen)==0)
    port=addr.ss_family==AF_INET ? ntohs(((struct sockaddr_in *)&addr)->sin_port)
      : ntohs(((struct sockaddr_in6 *)&addr)->sin6_port);
  char expected[160], origin[176];
  snprintf(expected,sizeof(expected),strchr(s->host,':') ? "[%s]:%d" : "%s:%d",s->host,port);
  int valid_host=r->host && strcmp(r->host,expected)==0;
  if(s->unix_socket)valid_host=r->host && (!strcmp(r->host,"localhost") || !strcmp(r->host,"localhost:80"));
  if (!s->unix_socket && !valid_host && (!strcmp(s->host,"127.0.0.1") || !strcmp(s->host,"localhost"))) {
    snprintf(expected,sizeof(expected),"localhost:%d",port);
    valid_host=r->host && strcmp(r->host,expected)==0;
    if (!valid_host) {
      snprintf(expected,sizeof(expected),"127.0.0.1:%d",port);
      valid_host=r->host && strcmp(r->host,expected)==0;
    }
  }
  snprintf(origin,sizeof(origin),"http://%s",r->host ? r->host : "");
  if (!valid_host || (r->origin && (s->unix_socket || strcmp(r->origin,origin)!=0))) {
    respond(c,403,"text/plain; charset=utf-8","forbidden origin or host\n",25,NULL);
    return;
  }

  /* AUTH, in C. When a token is configured every request must carry it; this
   * is checked before the handler is reached, so no Lua route can forget to. */
  if (s->token) {
    const char *got = r->auth;
    const char *bearer = NULL;
    if (got) {
      if (strncasecmp(got, "bearer ", 7) == 0) bearer = got + 7;

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
    respond(c, 500, "text/plain; charset=utf-8", msg,
      n<0 ? 0 : (size_t)n<sizeof msg ? (size_t)n : sizeof msg-1, NULL);
    return;
  }

  /* handler -> "stream", or (status, body, headers) */
  if (lua_type(L, -3) == LUA_TSTRING && strcmp(lua_tostring(L, -3), "stream") == 0) {
    size_t channel_length=0,initial_length=0;
    const char *channel=lua_isnil(L,-2) ? "" : lua_type(L,-2)==LUA_TSTRING ? lua_tolstring(L,-2,&channel_length) : NULL;
    const char *initial=lua_isnil(L,-1) ? NULL : lua_type(L,-1)==LUA_TSTRING ? lua_tolstring(L,-1,&initial_length) : NULL;
    if(!channel || channel_length>128 || memchr(channel,0,channel_length) || memchr(channel,'\r',channel_length) || memchr(channel,'\n',channel_length)
      || (!lua_isnil(L,-1) && !initial) || initial_length>MAX_WRITE_QUEUE-256) {
      lua_settop(L,top);respond(c,500,"text/plain; charset=utf-8","invalid stream\n",15,NULL);return;
    }
    memcpy(c->channel,channel,channel_length);c->channel[channel_length]=0;
    respond_stream(c,initial,initial_length);
    lua_settop(L, top);
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
  if(!bcopy){lua_settop(L,top);conn_close(c);return;}
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
  if (st == 0) { req_free(&r); return; }              /* need more bytes */
  /* one request per connection: drop what was consumed and stop reading */
  uv_read_stop(stream);
  c->len = 0;
  if (c->buf) c->buf[0] = 0;
  handle_request(c, &r);
  req_free(&r);
  if(c->is_stream){free(c->buf);c->buf=NULL;c->cap=c->len=0;}
}

static void on_connection(uv_stream_t *server, int status) {
  Server *s = (Server *)server->data;
  if (status != 0 || s->stopped) return;
  Conn *c = calloc(1, sizeof(*c));
  if (!c) return;
  c->srv = s;
  int initialized=s->unix_socket ? uv_pipe_init(server->loop,&c->io.pipe,0) : uv_tcp_init(server->loop,&c->io.tcp);
  if(initialized){free(c);return;}
  s->handles++;conn_stream(c)->data=c;
  if (uv_accept(server,conn_stream(c)) != 0 || s->nconns>=MAX_CONNS) {
    conn_close(c);
    return;
  }
#ifndef _WIN32
  if(s->unix_socket) {
    uv_os_fd_t fd;uid_t uid=(uid_t)-1;
    if(uv_fileno((uv_handle_t *)conn_stream(c),&fd)){conn_close(c);return;}
#if defined(__linux__)
    struct ucred credentials;socklen_t length=sizeof credentials;
    if(!getsockopt(fd,SOL_SOCKET,SO_PEERCRED,&credentials,&length))uid=credentials.uid;
#else
    gid_t gid;if(getpeereid(fd,&uid,&gid))uid=(uid_t)-1;
#endif
    if(uid!=geteuid()){conn_close(c);return;}
  }
#endif
  c->next = s->conns;
  s->conns = c;
  s->nconns++;
  if(uv_read_start(conn_stream(c),alloc_cb,on_read))conn_close(c);
}

/* ---- Lua surface ---------------------------------------------------------- */

static Server *check_server(lua_State *L, int idx) {
  ServerOwner *owner=luaL_checkudata(L,idx,SERVER_MT);
  luaL_argcheck(L,owner->native!=NULL,idx,"closed server");return owner->native;
}
static void stop_server(Server *s,lua_State *L);
static int bind_socket(Server *s) {
#ifdef _WIN32
  (void)s;return UV_ENOSYS;
#else
  struct sockaddr_un address={0};size_t length=strlen(s->socket_path);
  if(!length || length>=sizeof address.sun_path || s->socket_path[0]!='/')return UV_EINVAL;
  char parent[sizeof s->socket_path];memcpy(parent,s->socket_path,length+1);
  char *slash=strrchr(parent,'/');if(!slash || slash==parent)return UV_EACCES;*slash=0;
  struct stat info;
  if(lstat(parent,&info)<0)return uv_translate_sys_error(errno);
  if(!S_ISDIR(info.st_mode) || info.st_uid!=geteuid() || (info.st_mode&077))return UV_EACCES;
  if(!lstat(s->socket_path,&info))return UV_EEXIST;
  if(errno!=ENOENT)return uv_translate_sys_error(errno);
  int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return uv_translate_sys_error(errno);
  int error=0;
  address.sun_family=AF_UNIX;memcpy(address.sun_path,s->socket_path,length+1);
  if(fcntl(fd,F_SETFD,FD_CLOEXEC)<0 || bind(fd,(struct sockaddr *)&address,sizeof address)<0)error=uv_translate_sys_error(errno);
  else if(lstat(s->socket_path,&info)<0)error=uv_translate_sys_error(errno);
  else if(!S_ISSOCK(info.st_mode) || info.st_uid!=geteuid())error=UV_EACCES;
  else {
    s->socket_dev=(uint64_t)info.st_dev;s->socket_ino=(uint64_t)info.st_ino;
    if(chmod(s->socket_path,0600)<0)error=uv_translate_sys_error(errno);
    else error=uv_pipe_open(&s->io.pipe,fd);
  }
  if(error)close(fd);
  /* Opening an already-bound fd leaves libuv's pipe_fname unset. Boggart owns
   * inode-checked unlink; uv_pipe_bind would unlink replacement paths on close. */
  return error;
#endif
}

static int l_listen(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_rawgetp(L,LUA_REGISTRYINDEX,&server_shutdown);int shutting_down=lua_toboolean(L,-1);lua_pop(L,1);
  if(shutting_down)return luaL_error(L,"control server loop is shutting down");

  lua_getfield(L,1,"socket");size_t path_len=0;const char *path=luaL_optlstring(L,-1,"",&path_len);
  char pathbuf[256];
  if(path_len>=sizeof pathbuf || strlen(path)!=path_len)return luaL_error(L,"invalid socket path");
  memcpy(pathbuf,path,path_len+1);lua_pop(L,1);

  lua_getfield(L, 1, "host");
  const char *host = luaL_optstring(L, -1, "127.0.0.1");
  char hostbuf[128];
  snprintf(hostbuf, sizeof(hostbuf), "%s", host);
  lua_pop(L, 1);

  lua_getfield(L, 1, "port");
  lua_Integer requested_port=luaL_optinteger(L,-1,0);
  if(requested_port<0 || requested_port>65535)return luaL_error(L,"invalid server port");
  int port=(int)requested_port;
  lua_pop(L, 1);
  lua_getfield(L,1,"body_limit");lua_Integer body_limit=luaL_optinteger(L,-1,MAX_BODY_BYTES);lua_pop(L,1);
  if(body_limit<1 || body_limit>MAX_BODY_BYTES)return luaL_error(L,"invalid body limit");

  lua_getfield(L, 1, "token");
  const char *token = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;
  char tokbuf[256] = {0};
  if (token) {
    size_t n=lua_rawlen(L,-1);
    if (n==0 || n>=sizeof(tokbuf) || strlen(token)!=n) return luaL_error(L,"invalid token length");
    memcpy(tokbuf,token,n+1);
  }
  lua_pop(L, 1);

  /* THE ENFORCEMENT. Binding somewhere the network can reach is a different
   * act from binding loopback, and it is refused outright without a token --
   * in C, where the Lua the agent rewrites cannot decide otherwise. */
  int loopback = (strcmp(hostbuf, "127.0.0.1") == 0 || strcmp(hostbuf, "::1") == 0
                  || strcmp(hostbuf, "localhost") == 0);
  lua_getfield(L, 1, "profile");
  const char *profile=lua_tostring(L,-1);
  int trusted=profile && strcmp(profile,"trusted_local")==0;
  if (profile && !trusted && strcmp(profile,"authenticated")!=0) return luaL_error(L,"unknown control profile");
  lua_pop(L,1);
  if (!pathbuf[0] && (!loopback || !trusted) && tokbuf[0] == 0) {
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
  int handler_index=lua_gettop(L);

  /* the loop, materialised the same way every other module does it */
  lua_getglobal(L, "require");
  lua_pushliteral(L, "uv");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    lua_pop(L, 1);
    return luaL_error(L, "serve.listen: no uv loop");
  }
  lua_pop(L, 1);
  uv_loop_t *loop = luv_loop(L);
  if (!loop) {
    return luaL_error(L, "serve.listen: no uv loop");
  }

  ServerOwner *owner=lua_newuserdatauv(L,sizeof *owner,0);owner->native=NULL;
  luaL_setmetatable(L,SERVER_MT);
  Server *s=calloc(1,sizeof *s);if(!s)return luaL_error(L,"server allocation failed");
  owner->native=s;lua_rawgeti(L,LUA_REGISTRYINDEX,LUA_RIDX_MAINTHREAD);s->L=lua_tothread(L,-1);lua_pop(L,1);
  s->handler_ref=LUA_NOREF;s->loop=loop;s->body_limit=(size_t)body_limit;
  s->unix_socket=pathbuf[0]!=0;memcpy(s->socket_path,pathbuf,strlen(pathbuf)+1);
  s->next=servers;servers=s;
  lua_pushvalue(L,handler_index);s->handler_ref=luaL_ref(L,LUA_REGISTRYINDEX);
  lua_pushboolean(L,1);lua_rawsetp(L,LUA_REGISTRYINDEX,&server_started);
  snprintf(s->host,sizeof(s->host),"%s",hostbuf);
  if (tokbuf[0]) {
    s->token_len = strlen(tokbuf);
    s->token = malloc(s->token_len + 1);
    if (!s->token) {stop_server(s,L);return luaL_error(L,"token allocation failed");}
    memcpy(s->token, tokbuf, s->token_len + 1);
  }
  int rc=s->unix_socket ? uv_pipe_init(loop,&s->io.pipe,0) : uv_tcp_init(loop,&s->io.tcp);
  if(!rc){s->initialized=1;s->handles++;server_stream(s)->data=s;}
  if(!rc && s->unix_socket)rc=bind_socket(s);
  else if(!rc) {
    struct sockaddr_storage addr;
    const char *bind_host=strcmp(hostbuf,"localhost")==0 ? "127.0.0.1" : hostbuf;
    rc=uv_ip4_addr(bind_host,port,(struct sockaddr_in *)&addr);
    if(rc)rc=uv_ip6_addr(bind_host,port,(struct sockaddr_in6 *)&addr);
    if(!rc)rc=uv_tcp_bind(&s->io.tcp,(const struct sockaddr *)&addr,0);
  }
  if(!rc)rc=uv_listen(server_stream(s),64,on_connection);
  if(rc){stop_server(s,L);lua_pushnil(L);lua_pushfstring(L,"listen failed: %s",uv_strerror(rc));return 2;}
  /* The listener must not by itself keep the process alive: a REPL that has
   * finished should still exit. Whatever wants the server up (serve mode)
   * holds the loop open on its own terms. */
  uv_unref((uv_handle_t *)server_stream(s));
  return 1;
}

static int l_port(lua_State *L) {
  Server *s = check_server(L, 1);
  if(s->unix_socket || s->stopped || !s->initialized){lua_pushnil(L);return 1;}
  struct sockaddr_storage ss;
  int nlen = (int)sizeof(ss);
  if (uv_tcp_getsockname(&s->io.tcp, (struct sockaddr *)&ss, &nlen) != 0) {
    lua_pushnil(L); return 1;
  }
  int port = 0;
  if (ss.ss_family == AF_INET) port = ntohs(((struct sockaddr_in *)&ss)->sin_port);
  else if (ss.ss_family == AF_INET6) port = ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
  lua_pushinteger(L, port);
  return 1;
}

static const char *channel_argument(lua_State *L,int index) {
  size_t length=0;const char *channel=luaL_checklstring(L,index,&length);
  luaL_argcheck(L,length<=128 && !memchr(channel,0,length) && !memchr(channel,'\r',length) && !memchr(channel,'\n',length),index,"invalid stream channel");
  return channel;
}
/* One SSE frame to the exact channel (empty = global). */
static int l_broadcast(lua_State *L) {
  Server *s = check_server(L, 1);
  size_t event_length=0;const char *event=luaL_checklstring(L,2,&event_length);
  luaL_argcheck(L,event_length>0 && event_length<=128 && !memchr(event,0,event_length) && !memchr(event,'\r',event_length) && !memchr(event,'\n',event_length),2,"invalid SSE event name");
  size_t dlen = 0;
  const char *data = luaL_optlstring(L, 3, "", &dlen);
  const char *channel=lua_isnoneornil(L,4) ? "" : channel_argument(L,4);
  int sent = 0;
  for (Conn *c = s->conns; c; c = c->next) {
    if (!c->is_stream || c->closing || strcmp(c->channel,channel)) continue;
    if(stream_write(c,event,event_length,data,dlen)==0)sent++;
  }
  lua_pushinteger(L, sent);
  return 1;
}

static int l_clients(lua_State *L) {
  Server *s = check_server(L, 1);
  const char *channel=lua_isnoneornil(L,2) ? NULL : channel_argument(L,2);
  int n = 0;
  for (Conn *c = s->conns; c; c = c->next) if (c->is_stream && !c->closing && (!channel || !strcmp(channel,c->channel))) n++;
  lua_pushinteger(L, n);
  return 1;
}
static int l_close_streams(lua_State *L) {
  Server *s=check_server(L,1);const char *channel=lua_isnoneornil(L,2) ? NULL : channel_argument(L,2);int count=0;
  for(Conn *c=s->conns;c;c=c->next)if(c->is_stream && !c->closing && (!channel || !strcmp(channel,c->channel))){conn_close(c);count++;}
  lua_pushinteger(L,count);return 1;
}

static void on_server_closed(uv_handle_t *h) {
  Server *s=h->data;s->initialized=0;s->handles--;server_free(s);
}
static void stop_server(Server *s,lua_State *L) {
  if(s->stopped)return;
  s->stopped=1;
  for(Conn *c=s->conns;c;){Conn *next=c->next;conn_close(c);c=next;}
  unlink_socket(s);
  if(s->initialized && !uv_is_closing((uv_handle_t *)server_stream(s)))uv_close((uv_handle_t *)server_stream(s),on_server_closed);
  if(s->handler_ref!=LUA_NOREF){luaL_unref(L,LUA_REGISTRYINDEX,s->handler_ref);s->handler_ref=LUA_NOREF;}
  free(s->token);s->token=NULL;
}

static int l_stop(lua_State *L) {
  Server *s = check_server(L, 1);
  int changed=!s->stopped;stop_server(s,L);lua_pushboolean(L,changed);
  return 1;
}

static int l_gc(lua_State *L) {
  ServerOwner *owner=luaL_testudata(L,1,SERVER_MT);
  if(owner && owner->native){Server *s=owner->native;owner->native=NULL;stop_server(s,L);s->released=1;server_free(s);}
  return 0;
}
void boggart_serve_shutdown(lua_State *L) {
  lua_rawgetp(L,LUA_REGISTRYINDEX,&server_started);int active=lua_toboolean(L,-1);lua_pop(L,1);if(!active)return;
  lua_pushboolean(L,1);lua_rawsetp(L,LUA_REGISTRYINDEX,&server_shutdown);
  uv_loop_t *loop=luv_loop(L);
  for(Server *s=servers;s;s=s->next)if(s->loop==loop)stop_server(s,L);
  for(;;) {
    int pending=0;for(Server *s=servers;s;s=s->next)if(s->loop==loop && s->handles){pending=1;break;}
    if(!pending)break;uv_run(loop,UV_RUN_NOWAIT);
  }
}
static int l_socket(lua_State *L) {
  Server *s=check_server(L,1);char path[sizeof s->socket_path];memcpy(path,s->socket_path,sizeof path);
  if(!path[0])lua_pushnil(L);else lua_pushstring(L,path);return 1;
}
static int l_verify_token(lua_State *L) {
  size_t a,b;const char *expected=luaL_checklstring(L,1,&a),*actual=luaL_checklstring(L,2,&b);
  lua_pushboolean(L,ct_equal(expected,a,actual,b));return 1;
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
  { "socket",    l_socket },
  { "broadcast", l_broadcast },
  { "clients",   l_clients },
  { "close_streams",l_close_streams },
  { "stop",      l_stop },
  { NULL, NULL }
};

static const luaL_Reg serve_lib[] = {
  { "listen", l_listen },
  { "token",  l_token },
  { "verify_token", l_verify_token },
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
