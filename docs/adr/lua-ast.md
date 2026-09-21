# Lua source indexing parser (BRAIN-25)

Status: implemented; qualification evidence lives in `.superpowers/sdd/BRAIN-25-report.md`.

## Decision and alternatives

Use the maintained tree-sitter Lua grammar v0.5.0 and tree-sitter C runtime v0.26.6, vendored at immutable commits. Lua owns normalization, lexical binding analysis and features. The native bridge only validates and parses; it never executes the submitted source.

The actual host is **Lua 5.5.1**, verified from `src/vendor/lua/src/lua.h`. Lua 5.5 adds global declarations, prefix attributes and named variadic parameters. The selected grammar explicitly implements these productions; the regression suite exercises them, including alpha-equivalence for named variadic parameters. See the [pinned grammar](https://github.com/tree-sitter-grammars/tree-sitter-lua/blob/10fe0054734eec83049514ea2e718b2a56acd0c9/grammar.js) and [official Lua 5.5 grammar](https://www.lua.org/manual/5.5/manual.html#9).

Alternatives evaluated against language and embedding constraints:

| Parser | Evidence and decision |
| --- | --- |
| tree-sitter-lua v0.5.0 | Selected. The maintained [release](https://github.com/tree-sitter-grammars/tree-sitter-lua/releases/tag/v0.5.0) and grammar support the actual language additions. Generated C parser/scanner embed without JavaScript, Node, an executable subprocess, or runtime dependency downloads. Tree structure, fields and byte spans support scope-aware analysis. |
| fstirlitz/luaparse | [Upstream options](https://github.com/fstirlitz/luaparse#parser-interface) enumerate Lua 5.1–5.3 and LuaJIT. It does not meet 5.5 syntax and would add a JavaScript runtime or a translation. Not selected. |
| thenumbernine/lua-parser | [Upstream](https://github.com/thenumbernine/lua-parser) offers a Lua AST and selectable language versions, with Lua ecosystem dependencies. Its advertised version examples do not establish complete 5.5 support. Porting and verifying those dependencies offers no advantage over an already generated compatible C grammar. Not selected. |
| Official Lua 5.5.1 parser alone | Exact syntax authority already vendored, but produces bytecode rather than an exposed source AST. Instrumenting the compiler would fork runtime internals and still require a source-tree representation. Use its compile-only validation, not bytecode as a substitute AST. |

Tree-sitter grammar acceptance is intentionally broader than host acceptance (for example LuaJIT numeric literals), and tree-sitter recovers from errors. Consequently, every input must first compile as text in a **separate, library-free Lua 5.5.1 VM**, and the resulting closure is discarded without invocation. Then the tree must have no error/recovery nodes. Either failure returns `nil,error`, with no partial index or candidate. Valid host syntax the grammar cannot represent also fails closed; indexing does not modify it to make it parse.

## Exact provenance and licenses

No generated files are regenerated during the build. The new vendor files are unmodified upstream files; per-file SHA-256 inventories are `src/vendor/tree-sitter/SHA256SUMS` and `src/vendor/tree-sitter-lua/SHA256SUMS` (paths relative to repository root).

- **tree-sitter v0.26.6**, commit `534c4a074cd461ab30d1c8a54bf733d3050221a0`, [source archive](https://codeload.github.com/tree-sitter/tree-sitter/tar.gz/534c4a074cd461ab30d1c8a54bf733d3050221a0), archive SHA-256 `20890a4b1f4aa46d9dc3b81b9f159636541f575663449b7101412f5560125ee5`. MIT, retained `src/vendor/tree-sitter/LICENSE`. Only `lib/include` and `lib/src` are retained. Bundled Unicode code has its own retained `lib/src/unicode/LICENSE` (Unicode/ICU notices), `README.md` and `ICU_SHA`.
- **tree-sitter-lua v0.5.0**, commit `10fe0054734eec83049514ea2e718b2a56acd0c9`, [source archive](https://codeload.github.com/tree-sitter-grammars/tree-sitter-lua/tar.gz/10fe0054734eec83049514ea2e718b2a56acd0c9), archive SHA-256 `82c3ca5808de02addd9c7fb5275d89260c6557019aa6e40ca52c0595bf1d33cd`. MIT, retained `src/vendor/tree-sitter-lua/LICENSE.md`. Retained `grammar.js` and generated `src` (parser, scanner, node metadata and headers).
- Existing **Lua 5.5.1**, [official source](https://www.lua.org/source/5.5/), MIT as documented in the existing vendor license/manual. `lua.h` SHA-256 at implementation: `5e00319e803893f4310b1206394c80b82f03f42609b40ceb306d92a6740d828e`.

Build the runtime amalgamation `lib/src/lib.c`, grammar `src/parser.c` and `src/scanner.c` as a static vendor target. `src/lmining_parser.c` exposes `luaopen_boggart_mining_parser`, registered as require-only `mining_parser` in CLI and embedded hosts. Lua module `mining.ast` is the public contract; callers should not persist raw parser trees.

## Public contract

`require('mining.ast').index(source, version)` returns an index or `nil,{code,message}`. `source` must be a string; optional `version` is source provenance, a string of at most 256 bytes, not a requested grammar version. The fixed parser matches the host language. Failures include `invalid_source`, `invalid_version`, `parse_error`, `resource_limit`, and `parser_unavailable`; message text is diagnostic, not a matching contract.

The index is plain data with `schema_version=1`, exact `source`, optional `version`, `source_hash=workflow.hash(source)` (SHA-256), parser identity, `nodes`, `sites`, `features`, and `unknowns`. No executable eligibility or semantic safety is inferred merely from successful indexing.

- `nodes` are normalized syntax-tree nodes in preorder, indexed by positive `id`, with `kind`, optional parent field name, `named`, `parent`, child IDs and `span`. Punctuation/operator nodes are retained so structure and predicates are unambiguous. Comments are excluded from the index, but always retained in source. Leaf spelling is `value`; bound locals additionally carry `binding`, `role`, and canonical `normalized` identity.
- All spans use **one-based byte offsets, inclusive start and exclusive end**. Lines and byte columns are one-based; columns are not Unicode character counts. `source:sub(span.start_byte,span.end_byte-1)` recovers exact syntax. Sites identify call/callee nodes and spans, ordered by source offset then node ID.
- `features.structure_hash` hashes a length-prefixed syntax-order serialization of node kinds, fields, child counts and canonical leaf values. `structure_hash_version=1` scopes this format. Whitespace/comments and local spelling do not affect it. Operators, literals, field/global names, attributes and lexical binding structure do. This is syntactic comparability, not proof of semantic equivalence. Equivalent literal spellings or redundant punctuation can have different hashes. Changes to parser/normalization require rebuilding indexes.
- `features.bindings` records declarations and implicit method `self`. `features.def_use` links reads/writes to their lexical declaration only, with `relation='lexical_binding'` and a captured flag. It does **not** claim reaching definitions, runtime values, execution ordering or deterministic call effects. Initializers are analyzed before new bindings, local functions bind before their bodies, loop initializer scopes exclude loop locals, repeat conditions include repeat locals, and fields/labels/attribute names are not variable references. `_ENV` spelling is deliberately retained.
- Every call has `resolution='unknown'`. `unknowns` records runtime call effects, table/metatable lookup, possible operator metamethods, closure environments/captured values, assignment value/control flow and goto uncertainty. A direct-looking function name does not establish purity, capabilities or determinism. Function declarations, metatables, mutation and closures prevent name-only effect inference.

## Resource and safety boundaries

The source limit is 262,144 bytes before either parser is invoked. The compile-only Lua VM has a hard 16 MiB allocation budget and the vendored compiler's own syntax nesting/variable limits. Tree-sitter checks cancellation every 100 parser operations, with at most 10,000 callback checks and a 250 ms process-CPU budget; timeout/work exhaustion returns `resource_limit`. Conversion limits the tree to 20,000 nodes and depth 128 before returning it to Lua. Output and subsequent analysis are consequently bounded by those limits. Comments count toward native tree resources even though excluded from normalized output. Limits are fixed internal ceilings, not input-controlled options.

The tree-sitter allocator is unchanged: source/work limits are **not a hard process-memory ceiling**, and upstream allocation exhaustion can abort the host. Replacing its global allocator per request would introduce races across host threads. Hosts requiring a hard memory/time isolation boundary should invoke this bounded operation in an existing isolated worker with OS limits; this API is not an OS sandbox. The short CPU budget is a refusal boundary, not a latency guarantee, and can be affected by concurrent process activity.

Native parser/tree ownership is guarded by a Lua userdata finalizer. Tree-to-Lua conversion runs under `lua_pcall`, and native resources are explicitly freed on either success or conversion failure. The analysis VM is always closed before allocating the result/error in the caller. No submitted source is executed, no libraries are opened for validation, and no subprocess/network/file effects arise from the source being indexed.
