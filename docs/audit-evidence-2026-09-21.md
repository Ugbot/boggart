# Audit verification evidence — 21 September 2026

Companion to [audit and roadmap](audit-roadmap-2026-09-21.md). These probes demonstrate defects; they are not application fixes or a complete security assessment.

## Environment and test execution

- Repository base: `c5cde86`, with pre-existing working-tree changes, including TypeSafe/judge.
- Platform: user's macOS workspace. Existing `./boggart`, reporting application version `0.2.0`.
- Compared each available `lua/<embedded-name>.lua` to `boggart.embedded(name)`: **141 equal, zero different**. Native sources and Studio assets were not rebuilt or equivalence-checked.
- Extracted the `foreach(suite ...)` list from `CMakeLists.txt`; invoked `./boggart --eval tests/<suite>.lua` separately for all 56 entries. Each process received its own temporary HOME/USERPROFILE/XDG_DATA_HOME/LOCALAPPDATA, with inherited BOGGART/Anthropic/OpenAI/TypeSafe environment settings removed.
- Initial result: 53 suites passed, three failed. `termrender` inherited `NO_COLOR`; removing it produced **75 assertions passed, zero failed**. `mcp` and `control` could not bind loopback sockets inside the sandbox; an authorized rerun outside that restriction produced **72/0** and **29/0**, respectively.
- Final result: **all 56 Lua suites passed**. This was not a fresh CMake build, the standalone native `termctl` smoke test, or a GUI test run.

Temporary logs, available in the audit environment:

```text
/var/folders/bb/xk0ymlz56y35thcpsrkph8mh0000gn/T/boggart-audit-ikip8jfv/
/var/folders/bb/xk0ymlz56y35thcpsrkph8mh0000gn/T/boggart-network-retest-nencgpnk/
```

No paid provider requests were made. Tests use local/scripted fixtures. The reproductions below use temporary files and in-process calls.

## Reproduction setup

Run each snippet in a **separate process with a fresh temporary BOGGART_HOME and HOME**. Do not use a normal user profile: the reload probe intentionally installs a broken temporary overlay. Place the snippets outside the repository and invoke:

```text
BOGGART_HOME=<fresh-temp>/data HOME=<fresh-temp> ./boggart --eval <probe.lua>
```

That line is a template: replace placeholders with actual absolute temporary paths. No repository source changes are required.

## A1: denied write through nested generated tool

```lua
local T, P = bog.tools, require("perm")
local st = {
  mode = "smart", headless = "deny", guards = false,
  tool_policy = { write = "deny", bash = "deny" }
}
local run = P.wrap_run(T.run, st)
local path = bog.userdir .. "/nested-proof.txt"
T.register_body("audit_nested", "probe", {},
  'return tools.call("write", {path=args.path,content="audit only"})',
  "session")
print("direct", run("write", {path=path, content="direct"}))
print("nested", run("audit_nested", {path=path}))
print("exists", sys.stat(path))
```

Observed: direct call returned `Tool error: [permission_error]`; nested call returned `Wrote ... (10 bytes, 1 lines)`; `sys.stat` reported `file`. `guards=false` disables heuristic guards for clarity; the explicit `write=deny` remains the intended prohibition.

Source: `lua/tools.lua` around lines 264–275, 878 and 1577; `lua/perm.lua` around line 415. Generated `tools.call` and callable tool wrappers reach raw `M.run`, outside the wrapping gate. Direct access to host capability tables is an additional design problem, not repaired solely by wrapping nested calls.

## A2: explicit allow skips chat and child deny

```lua
print(require("perm").decide("bash", {command="echo harmless"}, {
  mode="chat", tool_policy={bash="allow"}, agent_rules={bash="deny"}
}))
```

Observed: `allow`, `you set this tool to allow`. No command is executed by this probe. Source: `lua/perm.lua`, `M.decide`, around line 372. The early return precedes agent narrowing and the final chat-mode check.

## A3: verifier/finalizer failure swallowed

```lua
local C = require("callable")
local n = C.new{
  run=function() return "success" end,
  finally=function() error("verification exploded") end
}
print("finally_error", pcall(function() return n({}) end))

package.loaded["skills.audit_verify"] = {
  run=function() return "unchecked success" end,
  verify=function() return false end
}
print("skill_verify_false", pcall(function()
  return require("skills").as_callable("audit_verify")({})
end))
```

Observed:

```text
finally_error       true    success
skill_verify_false  true    unchecked success
```

Source: `lua/callable.lua` around lines 129–139; `lua/skills.lua` around lines 778–788. The separate `callable.verify(...)` combinator raises within its run path; this finding is specifically finalizer errors and skill verifiers attached as finalizers.

## A4: nested generated tool clears outer instruction hook

```lua
local T = bog.tools
T.register_body("audit_inner", "probe", {}, 'return "inner"', "session")
T.register_body("audit_outer", "probe", {}, [[
  tools.call("audit_inner", {})
  local n=0
  for i=1,1000000 do n=n+i end
  return "completed million-iteration loop"
]], "session")
T.LIMITS.instructions=10000
T.LIMITS.check_every=1000
print(T.run("audit_outer", {}))
```

Observed: `completed million-iteration loop`. Finite loop deliberately used instead of an infinite-loop attack. Source: `lua/tools.lua`, `run_bounded`, around lines 836–862; the inner call installs a hook and then clears it without restoring the outer hook.

## A6: failed reload leaves new worker binding

```lua
local old = bog.worker
sys.mkdir_p(bog.userdir .. "/lua")
local f = assert(io.open(bog.userdir .. "/lua/perm.lua", "w"))
f:write('error("audit simulated load error")')
f:close()
local success = bog.reload()
print("reload", success, "worker_restored", bog.worker == old)
```

Observed: `reload false worker_restored false`. Source: `lua/boot.lua`, `CORE`/`wire` around lines 106–122, rollback around lines 297–305. This is one reproducible alias mismatch, not an exhaustive inventory of reload effects.

## A7: populated sessions missing from control route

```lua
local S = require("control")
bog.store.sess_create("audit session", "test-model")
print("real_sessions", #bog.store.sess_list(20))
for _, r in ipairs(S.routes) do
  if r.method == "GET" and r.pattern == "^/sessions$" then
    local status, body = r.fn({})
    print("route_sessions", status, body)
  end
end
```

Observed: `real_sessions 1`, then `route_sessions 200 {"sessions":{}}`. Invokes the exact route handler without opening a socket. Source: `lua/control.lua` around line 134, versus `lua/store.lua` around line 1010.

## A8: duplicate tool-before observation

```lua
local count=0
local h=bog.events.on("tool:before", function() count=count+1 end)
bog.tools.register("audit_noop", {run=function() return "ok" end})
local run=require("perm").wrap_run(bog.tools.run, {
  mode="auto", guards=false, tool_policy={}
})
run("audit_noop", {})
bog.events.off(h)
print("tool_before_count", count)
```

Observed: `tool_before_count 2`. Source: `lua/perm.lua` around line 443 and `lua/tools.lua` around line 886. Payload shapes also differ: gate uses `tool`, dispatcher uses `name`.

## Native module probe

Compiled this source in a temporary directory:

```c
#include "lua.h"
#include "lauxlib.h"
int luaopen_auditnative(lua_State *L) {
  luaL_checkversion(L);
  lua_pushliteral(L, "native-module-ok");
  return 1;
}
```

Using macOS `cc -bundle -undefined dynamic_lookup -Isrc/vendor/lua/src <source> -o <temp>/auditnative.so`, then from an isolated CLI:

```lua
local f,e = package.loadlib("<absolute-temp>/auditnative.so", "luaopen_auditnative")
print("load", type(f), e)
if f then print("invoke", f()) end
```

Observed: successful compilation, `load function nil`, `invoke native-module-ok`, process exit 0. This verifies an ordinary native Lua module on this macOS CLI only. It does not establish a supported ABI, safe unloading, Studio support, Windows DLL support or Linux exports.

## Findings not dynamically exercised

A5's unbounded event-handler execution, A9's default local-control authentication posture, raw capability exposure, panel allocation limits and cross-platform release gaps are source findings or engineering risks. No infinite handler was run, no browser-origin attack was attempted, no credential was accessed, and no native memory-safety verdict is claimed.
