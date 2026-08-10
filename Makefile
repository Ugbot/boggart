# boggart — single embedded exe: C core + embedded Lua 5.4 harness + libcurl.
CC      ?= cc
CFLAGS  ?= -O2 -g -Wall -Wextra -Wno-unused-parameter
LDFLAGS ?=
LDLIBS  ?= -lcurl

SRC       := src
VENDOR    := $(SRC)/vendor
LUADIR    := lua
LUA_SRC   := $(VENDOR)/lua/src

# Vendored Lua as a static archive (exclude the two files that define main()).
LUA_OBJS  := $(patsubst %.c,%.o,$(filter-out $(LUA_SRC)/lua.c $(LUA_SRC)/luac.c,$(wildcard $(LUA_SRC)/*.c)))
LUA_LIB   := $(VENDOR)/liblua.a

# Vendored SQLite amalgamation, compiled with FTS5 and warnings suppressed
# (upstream code). Single-threaded build; no loadable extensions.
SQLITE_DIR    := $(VENDOR)/sqlite
SQLITE_OBJ    := $(SQLITE_DIR)/sqlite3.o
SQLITE_CFLAGS := -O2 -DSQLITE_ENABLE_FTS5 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION -w

# Vendored cJSON (MIT) for the C MCP client.
CJSON_DIR    := $(VENDOR)/cjson
CJSON_OBJ    := $(CJSON_DIR)/cJSON.o
CJSON_CFLAGS := -O2 -w

# Our C sources. embedded.c is generated. JSON for Lua is a pure-Lua module.
CORE_SRC  := $(SRC)/boggart.c $(SRC)/lhttp.c $(SRC)/lsys.c $(SRC)/ldb.c $(SRC)/lswarm.c $(SRC)/lmcp.c $(SRC)/embedded.c $(VENDOR)/linenoise.c
CORE_OBJS := $(CORE_SRC:.c=.o)

INCLUDES  := -I$(LUA_SRC) -I$(VENDOR) -I$(SRC) -I$(SQLITE_DIR) -I$(CJSON_DIR)

# macOS libcurl lives in the SDK; add readline-free linenoise. LUA_USE_MACOSX
# gives Lua dlopen/popen support.
LUA_PLAT  := -DLUA_USE_MACOSX

BIN := boggart

.PHONY: all clean test embedded

all: $(BIN)

# --- vendored Lua ---------------------------------------------------------
$(LUA_SRC)/%.o: $(LUA_SRC)/%.c
	$(CC) $(CFLAGS) $(LUA_PLAT) -c $< -o $@

$(LUA_LIB): $(LUA_OBJS)
	ar rcs $@ $^

# --- generated embedded Lua ----------------------------------------------
# Rebuild whenever any Lua source changes.
$(SRC)/embedded.c: $(shell find $(LUADIR) -name '*.lua') tools/gen_embedded.sh
	sh tools/gen_embedded.sh $(LUADIR) > $@

embedded: $(SRC)/embedded.c

# --- our objects ----------------------------------------------------------
$(SRC)/%.o: $(SRC)/%.c
	$(CC) $(CFLAGS) $(LUA_PLAT) $(INCLUDES) -c $< -o $@

$(VENDOR)/linenoise.o: $(VENDOR)/linenoise.c
	$(CC) $(CFLAGS) -c $< -o $@

$(SQLITE_OBJ): $(SQLITE_DIR)/sqlite3.c
	$(CC) $(SQLITE_CFLAGS) -c $< -o $@

$(CJSON_OBJ): $(CJSON_DIR)/cJSON.c
	$(CC) $(CJSON_CFLAGS) -c $< -o $@

# --- link -----------------------------------------------------------------
$(BIN): $(CORE_OBJS) $(SQLITE_OBJ) $(CJSON_OBJ) $(LUA_LIB)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(CORE_OBJS) $(SQLITE_OBJ) $(CJSON_OBJ) $(LUA_LIB) $(LDLIBS)

test: $(BIN)
	@tmp=$$(mktemp -d); \
	HOME=$$tmp ./$(BIN) --eval tests/test.lua && \
	HOME=$$tmp ./$(BIN) --eval tests/integration.lua && \
	HOME=$$tmp ./$(BIN) --eval tests/swarm.lua && \
	HOME=$$tmp ./$(BIN) --eval tests/mcp.lua; \
	rc=$$?; rm -rf $$tmp; exit $$rc

clean:
	rm -f $(BIN) $(CORE_OBJS) $(SQLITE_OBJ) $(CJSON_OBJ) $(LUA_OBJS) $(LUA_LIB) $(SRC)/embedded.c
