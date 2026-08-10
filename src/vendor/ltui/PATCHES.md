# ltui vendor patches

Upstream: <https://github.com/tboox/ltui> (Apache-2.0, © tboox).
Vendored at `master`, 2026-08-10.

Layout differs from upstream because boggart splits Lua from C:

| upstream | here | why |
|---|---|---|
| `src/ltui.lua`, `src/ltui/**.lua` | `lua/ltui.lua`, `lua/ltui/**.lua` | picked up by `tools/bake_embedded.cmake`, so they are embedded in the binary *and* overlay-mutable under `~/.boggart/lua/` — the agent can rewrite its own dashboard |
| `src/core/curses/curses.c` | `src/vendor/ltui/curses.c` | the only C in ltui |
| `src/core/pdcurses/` | `src/vendor/pdcurses/` | Windows curses backend |

Three patches, all fixing real breakage rather than style. Everything else is
byte-for-byte upstream — deliberately, so the next re-vendor is a clean drop-in.

## 1. `curses.c` — `lua_strlen` removed in Lua 5.4

`lua_strlen` was a Lua 5.0/5.1 macro. It survives in neither 5.4 nor its
`LUA_COMPAT_5_3` block, so the file would not compile.

```c
-    if (n < 0) n = (int)lua_strlen(lua, 2);
+    if (n < 0) n = (int)lua_rawlen(lua, 2);
```

Note the *other* 5.1-isms need no patch: `curses.c` defines `LUA_COMPAT_5_1`,
`LUA_COMPAT_5_3` and `LUA_COMPAT_ALL` itself before including `luaconf.h`, so
its 20 `luaL_checkint` calls and 1 `luaL_optint` resolve fine.

## 2. `curses.c` — `setlocale(LC_ALL, "")` corrupts JSON

`luaopen_ltui_lcurses` calls `setlocale(LC_ALL, "")` so ncurses can render wide
glyphs. That also adopts the user's `LC_NUMERIC`, and in any comma-decimal
locale (de_DE, fr_FR, pt_BR …) `printf("%.14g", 1.5)` then yields `1,5`.
`lua/json.lua` formats numbers exactly that way, so **every request body
boggart sent would be malformed JSON** — but only for users in those locales,
and only after the TUI had been loaded. Curses needs `LC_CTYPE`, not
`LC_NUMERIC`, so we pin the latter straight back:

```c
     setlocale(LC_ALL, "");
+    setlocale(LC_NUMERIC, "C");
```

Guarded by `tests/ltui.lua`.

## 3. `lua/ltui/base/table.lua` — destroys stock `table.unpack`

Upstream carries a Lua 5.1 polyfill:

```lua
table.unpack = unpack
```

The global `unpack` was removed in Lua 5.2. On our vendored 5.4 it is `nil`, so
this assigns nil and **deletes the real `table.unpack` process-wide** the moment
ltui loads. Fixed to prefer the real one, and to read the legacy global via
`rawget` so `strict.lua` does not reject it:

```lua
table.unpack = table.unpack or rawget(_G, "unpack")
```

Guarded by `tests/ltui.lua`.

## Not patched, but worth knowing

**ltui monkey-patches the stdlib.** `base/string.lua`, `base/table.lua` and
`base/os.lua` do `local string = string or {}` — which binds the *global*
table — then add methods to it. This is load-bearing: ltui calls
`str:startswith(...)` on plain string literals, which only resolves if the
global `string` table carries the method. So `require("ltui")` permanently adds:

- `string`: `append decode encode find_last ipattern join ltrim rtrim split startswith trim tryformat wcswidth wcwidth`
- `table`: `clear imap is_array is_dictionary join keys map pack reverse slice unique unwrap values wrap`
- `os`: `host iorun isfile pbcopy pbpaste raise run`

Checked against the Lua 5.4 stdlib: the only name collision is `table.pack`, and
ltui's implementation (`{ n = select("#", ...), ... }`) is semantically identical
to the built-in, so it is harmless. Nothing else shadows a stock function.

**`strict.lua` compatibility.** All 32 ltui modules use `local view = view or
object()`, an undefined-global read that `strict.lua` rejects by design. Rather
than fork every file, load ltui through `strict.without(require, "ltui")`, which
lifts the guard for the duration and restores it afterwards. `lua/ltui.lua`
requires the whole tree eagerly, so one call covers all 37 modules.
