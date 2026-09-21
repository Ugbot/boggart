# Lua parser compatibility reconnaissance

BRAIN-25 preparation, 21 September 2026. This is a shortlist and validation plan,
not a selected dependency or a claim that AST indexing is implemented.

## Runtime baseline

The checked-in `src/vendor/lua/src/lua.h` defines major 5, minor 5, release 1.
The [official Lua 5.5 manual](https://www.lua.org/manual/5.5/manual.html) documents
explicit global declarations and declaration attributes as part of the language.
A parser must cover actual Boggart syntax, including lexical scoping, rather
than assuming compatibility from a general Lua label. The local Lua compiler
can provide a syntax-validity cross-check, but its bytecode is not a source AST.

## Candidates to test

- [tree-sitter-lua](https://github.com/tree-sitter-grammars/tree-sitter-lua)
  advertises Lua 5.x/LuaJIT and an MIT license. Its inspected
  [grammar source](https://raw.githubusercontent.com/tree-sitter-grammars/tree-sitter-lua/main/grammar.js)
  contains global declarations, contextual `global`, and declaration attributes.
  That makes it a plausible candidate, not proven semantic compatibility. It also
  accepts LuaJIT numeric forms: tree-sitter acceptance alone cannot establish
  executable validity in Boggart. Reject recovered ERROR/missing nodes and verify
  the source with Boggart's exact compiler before executable eligibility.
- [luaparse](https://github.com/fstirlitz/luaparse) exposes AST ranges and scope
  tracking, but its documented version options stop at 5.3 plus LuaJIT. It is
  JavaScript-based. It cannot be selected unchanged as a complete parser for
  Boggart's current runtime.
- Boggart already vendors Lua's lexer/parser C sources. They are authoritative
  for runtime syntax, but inspection found no exported source-AST API. Instrumenting
  the compiler would introduce a maintained native fork; compare that cost against
  embedding an external parser before choosing it.

The sibling Station checkout has a tree-sitter loader/indexer, but a bounded
filename/source search found no vendored Lua grammar or explicit Lua language
registration. This is a negative search result, not proof that a dynamically
installed language pack cannot supply it. Do not make local AST indexing depend
on an unverified Station language capability.

## BRAIN-25 selection gate

Pin the chosen runtime/grammar commits and license after real fixture tests.
Test UTF-8 and byte offsets, long strings/comments, escaped literals, operators,
attributes/global declarations, closures/upvalues, shadowing, numeric/generic
loops, repeat-scope rules, labels/goto, varargs and dynamically selected calls.
Compare alpha-renamed lexical bindings without renaming field names, literal
keys or branch predicates. Preserve original source bytes/hash, distinguish
syntax features from semantic proof, and retain unknown calls/aliasing. Station
can provide optional indexing services, but the local workflow source must remain
searchable when its daemon is unavailable.
