/* Bounded, non-executing Lua 5.5 validation and tree-sitter syntax trees. */
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include "lua.h"
#include "lauxlib.h"
#include "tree_sitter/api.h"

extern const TSLanguage *tree_sitter_lua(void);
#define SOURCE_LIMIT 262144u
#define NODE_LIMIT 20000u
#define DEPTH_LIMIT 128u
#define VALIDATION_MEMORY (16u * 1024u * 1024u)

typedef struct { size_t used; } ValidationMemory;
typedef struct {
  const char *source;
  uint32_t length;
  unsigned checks;
  clock_t started;
} ParseBudget;
typedef struct { TSTree *tree; TSParser *parser; unsigned nodes; } TreeOwner;

static void *validation_alloc(void *ud, void *ptr, size_t old, size_t size) {
  ValidationMemory *m = (ValidationMemory *)ud;
  if (!ptr) old = 0;
  if (!size) { free(ptr); m->used -= old; return NULL; }
  if (size > VALIDATION_MEMORY || m->used - old > VALIDATION_MEMORY - size) return NULL;
  void *next = realloc(ptr, size);
  if (next) m->used = m->used - old + size;
  return next;
}
static int failure(lua_State *L, const char *code, const char *message) {
  lua_pushnil(L);
  lua_createtable(L, 0, 2);
  lua_pushstring(L, code); lua_setfield(L, -2, "code");
  lua_pushstring(L, message); lua_setfield(L, -2, "message");
  return 2;
}
static void dispose(TreeOwner *o) {
  if (o->tree) { ts_tree_delete(o->tree); o->tree = NULL; }
  if (o->parser) { ts_parser_delete(o->parser); o->parser = NULL; }
}
static int owner_gc(lua_State *L) { dispose(lua_touserdata(L, 1)); return 0; }
static bool cancelled(TSParseState *state) {
  ParseBudget *b = (ParseBudget *)state->payload;
  return ++b->checks > 10000 || (clock() - b->started) > CLOCKS_PER_SEC / 4;
}
static const char *read_source(void *payload, uint32_t byte, TSPoint point, uint32_t *count) {
  ParseBudget *b = (ParseBudget *)payload;
  (void)point;
  *count = byte < b->length ? b->length - byte : 0;
  return b->source + (byte < b->length ? byte : b->length);
}
static void integer_field(lua_State *L, const char *key, lua_Integer value) {
  lua_pushinteger(L, value); lua_setfield(L, -2, key);
}
static void push_node(lua_State *L, TreeOwner *owner, TSNode node, const char *field, unsigned depth) {
  if (depth > DEPTH_LIMIT || ++owner->nodes > NODE_LIMIT)
    luaL_error(L, "syntax tree exceeds depth/node limit");
  if (!lua_checkstack(L, 12)) luaL_error(L, "syntax tree exceeds Lua stack limit");
  lua_createtable(L, 0, 10);
  lua_pushstring(L, ts_node_type(node)); lua_setfield(L, -2, "kind");
  if (field) { lua_pushstring(L, field); lua_setfield(L, -2, "field"); }
  lua_pushboolean(L, ts_node_is_named(node)); lua_setfield(L, -2, "named");
  integer_field(L, "start_byte", ts_node_start_byte(node) + 1);
  integer_field(L, "end_byte", ts_node_end_byte(node) + 1);
  TSPoint start = ts_node_start_point(node), end = ts_node_end_point(node);
  integer_field(L, "start_line", start.row + 1);
  integer_field(L, "start_column", start.column + 1);
  integer_field(L, "end_line", end.row + 1);
  integer_field(L, "end_column", end.column + 1);
  uint32_t count = ts_node_child_count(node);
  lua_createtable(L, (int)count, 0);
  for (uint32_t i = 0; i < count; ++i) {
    push_node(L, owner, ts_node_child(node, i), ts_node_field_name_for_child(node, i), depth + 1);
    lua_rawseti(L, -2, i + 1);
  }
  lua_setfield(L, -2, "children");
}
static int convert_tree(lua_State *L) {
  TreeOwner *o = lua_touserdata(L, 1);
  push_node(L, o, ts_tree_root_node(o->tree), NULL, 0);
  return 1;
}
static int parse(lua_State *L) {
  if (lua_type(L, 1) != LUA_TSTRING) return failure(L, "invalid_source", "source must be a string");
  size_t length;
  const char *source = lua_tolstring(L, 1, &length);
  if (length > SOURCE_LIMIT) return failure(L, "resource_limit", "source exceeds 262144 bytes");
  /* Compile only in a fresh VM with no libraries and a hard allocation budget.
     Never call the resulting function or transfer it to the caller's VM. */
  ValidationMemory memory = {0};
  lua_State *validation = lua_newstate(validation_alloc, &memory, 0);
  if (!validation) return failure(L, "resource_limit", "validation memory exhausted");
  int status = luaL_loadbufferx(validation, source, length, "@mined-source", "t");
  char diagnostic[512];
  if (status != LUA_OK) {
    const char *message = lua_tostring(validation, -1);
    snprintf(diagnostic, sizeof diagnostic, "%s", message ? message : "Lua syntax validation failed");
  }
  lua_close(validation);
  if (status != LUA_OK) return failure(L, status == LUA_ERRMEM ? "resource_limit" : "parse_error", diagnostic);

  /* A GC guard covers Lua allocation failure; protected conversion lets us also
     release native ownership immediately on conversion errors. */
  TreeOwner *owner = lua_newuserdatauv(L, sizeof *owner, 0);
  memset(owner, 0, sizeof *owner);
  luaL_setmetatable(L, "boggart.mining_parser.owner");
  int owner_index = lua_gettop(L);
  owner->parser = ts_parser_new();
  if (!owner->parser || !ts_parser_set_language(owner->parser, tree_sitter_lua())) {
    dispose(owner); return failure(L, "parser_unavailable", "incompatible parser language");
  }
  ParseBudget budget = {source, (uint32_t)length, 0, clock()};
  TSInput input = {&budget, read_source, TSInputEncodingUTF8, NULL};
  TSParseOptions options = {&budget, cancelled};
  owner->tree = ts_parser_parse_with_options(owner->parser, NULL, input, options);
  if (!owner->tree) { dispose(owner); return failure(L, "resource_limit", "parser work budget exhausted"); }
  if (ts_node_has_error(ts_tree_root_node(owner->tree))) {
    dispose(owner); return failure(L, "parse_error", "source is unsupported by the pinned syntax grammar");
  }
  lua_pushcfunction(L, convert_tree); lua_pushvalue(L, owner_index);
  status = lua_pcall(L, 1, 1, 0);
  dispose(owner);
  if (status != LUA_OK) {
    lua_pop(L, 1);
    return failure(L, "resource_limit", "syntax tree conversion exceeded resources");
  }
  return 1;
}
int luaopen_boggart_mining_parser(lua_State *L) {
  if (luaL_newmetatable(L, "boggart.mining_parser.owner")) {
    lua_pushcfunction(L, owner_gc); lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
  lua_createtable(L, 0, 1);
  lua_pushcfunction(L, parse); lua_setfield(L, -2, "parse");
  return 1;
}
