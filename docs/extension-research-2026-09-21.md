# Extension architecture research — 2026-09-21

Recommendation: make Lua the normal Boggart extension language, provide a small versioned host API and lifecycle, use MCP for independently deployed services, and treat in-process native modules as an explicit advanced tier. A native loader alone does not create a usable plugin ecosystem.

This is external research and design advice, not an implementation or a claim that the current binaries support third-party native modules. Facts below cite primary sources checked on the date above. Recommendations are explicitly labeled.

## Lua and native modules

**Facts.** Lua's current release is 5.5.1. Releases within one Lua version are ABI compatible; different versions (for example 5.4 and 5.5) are not, and native modules must be rebuilt. Precompiled bytecode also cannot be assumed portable across versions. [Lua version policy](https://www.lua.org/versions.html)

`require` uses `package.loaded`, then ordered searchers; the standard searchers cover preloaded modules, Lua files and C libraries. C module discovery uses `package.cpath` and a `luaopen_…` entry point. `package.loadlib` links a named library and resolves a named C function directly. It bypasses ordinary module lookup. `luaL_checkversion` checks the Lua version and numeric types. The manual explicitly describes `loadlib` as insecure: it can reach arbitrary readable dynamic libraries, and an incompatible function can cause an access violation. [Lua 5.5 modules](https://www.lua.org/manual/5.5/manual.html#6.4), [version check](https://www.lua.org/manual/5.5/manual.html#luaL_checkversion)

**Local observations.** The vendored [lua.h](../src/vendor/lua/src/lua.h) declares 5.5.1. [CMakeLists.txt](../CMakeLists.txt) builds `lua_vendor` statically and selects Lua's platform dynamic-loading support. Its “vendored Lua 5.4” comment is stale. [boot.lua](../lua/boot.lua) appends an embedded fallback searcher. The reviewed CMake file contains no explicit `ENABLE_EXPORTS`, `-rdynamic`, or `dynamic_lookup` setting. This is a source observation, not a tested verdict about symbols exported by a particular binary.

**Recommendations.** Before advertising native support, build and load a tiny third-party module on each supported OS/architecture against both front ends. Exercise actual Lua API calls, error propagation, userdata cleanup and shutdown. Verify executable exports/import libraries and linker behavior; do not infer them from `package.cpath` existing.

For an initial native SDK, require Boggart's Lua headers/configuration, declare supported OS/architecture combinations, and call the version check at initialization. Do not attach a module's separately embedded Lua runtime to the host's `lua_State`. Keep host entry points on the owning event-loop thread; worker results should return through queued messages. Use an explicit resource disposer and a restart requirement for native upgrades, rather than promising unload while callbacks, userdata or native threads remain alive. These are proposed engineering policies, not Lua guarantees.

There are two different ABI decisions: ordinary Lua C modules depend on the Lua ABI; a Boggart-specific function-table ABI could hide Lua and expose opaque handles plus a `struct_size`/version negotiation. The latter offers more control but creates a second SDK to maintain. Defer it until a concrete extension needs it.

## Useful precedents

| System | Verified design | Lesson proposed for Boggart |
| --- | --- | --- |
| VS Code | Local/remote Node hosts and a browser worker host; placement considers runtime support and `extensionKind`. Activation events enable lazy loading. [Host documentation](https://code.visualstudio.com/api/advanced-topics/extension-host) | Separate engine extensions from Studio contributions; declare surfaces and required features instead of assuming every extension has a window. Lazy activation can keep startup predictable. |
| VS Code packaging | A manifest records identity, version, entry points and compatible editor versions through `engines.vscode`. [Manifest](https://code.visualstudio.com/api/references/extension-manifest) | Adopt a minimal declarative manifest before a marketplace: identity, extension version, host API range, entry point and dependencies. |
| Neovim Lua | Lua 5.1 is the permanent language interface. LuaJIT facilities such as FFI are not universally guaranteed. [Lua documentation](https://neovim.io/doc/user/lua/#lua-compat) | Copy its explicit compatibility stance, not its language version. Boggart should document its Lua 5.5 baseline and avoid implying Neovim plugins are directly reusable. |
| Neovim API | Public functions/events have a stated compatibility contract; additions are generally optional, while private interfaces are excluded. [API contract](https://neovim.io/doc/user/api/#api-contract) | Publish a deliberately small `bog.ext` contract and distinguish it from replaceable harness internals. Functionality being reachable through `require` should not automatically make it stable API. |
| pi coding agent | Extensions register tools, commands and event handlers. Global/project discovery exists; project extensions require project trust. Extensions run with full system permissions. Reload emits shutdown/start lifecycle events; an already running handler retains its old call frame. [Extension guide](https://raw.githubusercontent.com/earendil-works/pi/main/packages/coding-agent/docs/extensions.md) | Make extension ownership, cleanup and reload generation explicit. Retain the distinction between trusted installed code and restricted model-generated code. A reload needs defined behavior for old callbacks and in-flight work. |

These are architectural comparisons, not claims that their hosting models automatically sandbox extensions. Process separation, permission enforcement and API compatibility are distinct concerns.

## MCP as the service boundary

**Facts.** The current specification resolves to 2026-07-28. Its architecture is stateless: requests carry version/capabilities; each host-managed client communicates with one server. Servers expose tools, resources and prompts and can be local processes or remote services. The host owns authorization and coordination. [Specification](https://modelcontextprotocol.io/specification/2026-07-28), [architecture](https://modelcontextprotocol.io/specification/2026-07-28/architecture)

Standard bindings are subprocess stdio and Streamable HTTP. Earlier revisions used an `initialize` handshake; interoperability with them requires the specified era detection/fallback. [Transports](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports)

**Recommendations.** Prefer MCP when an extension needs an existing Python/Rust/C++ service, independent dependency management, remote execution or restartable process lifetime. A process boundary contains ordinary crashes but does not itself restrict filesystem or network access. Enforce permissions at the actual execution boundary when needed.

Keep Lua for low-latency host orchestration and UI composition. Use a Lua adapter when one installed package contributes both Studio UI and MCP-backed computation. Avoid shipping every UI interaction through MCP merely to make the architecture uniform. Preserve explicit protocol-version tests: older advice assuming all MCP connections initialize is stale for the current specification.

## Proposed implementation order

1. Inventory current extension surfaces and designate stable host functions, event schemas and supported front ends. Add feature queries and an API compatibility version independently of the application version.
2. Add extension identity and ownership to tool, command, event and panel registrations. A disposer should remove everything owned by one extension. Define duplicate-name policy and deterministic activation order.
3. Add a manifest and a single discover/validate/activate/deactivate pipeline. Keep executable project extensions behind the existing trust model; importing a workspace must not silently install privileged code.
4. Define reload as a transaction at a safe boundary: stage code, validate registrations, activate a new generation, retire old resources, and report failures. Do not claim arbitrary side effects can be rolled back.
5. Expose diagnostics: extension version, source, API requirements, active surface, registrations, failures and reload status. Reuse `doctor` and the library UI.
6. Validate the native probe matrix before supporting native modules. Add the larger ABI/package-distribution machinery only when required by an actual extension.

Suggested acceptance cases: one Lua package works in CLI and Studio; an optional Studio contribution is skipped cleanly in CLI; incompatible API requirements fail before activation; repeated reload does not duplicate handlers; failed activation leaves the prior usable generation intact where staging permits; a native module either loads on a declared supported platform or produces an actionable compatibility error; service failure leaves the host responsive.

No code was modified or native compatibility tested as part of this research.
