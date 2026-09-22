# Novel evidence workflows

The four `examples/workflows/novel_{character,timeline,cleanup,wordcount}.lua` domain sources return `run(ctx)` and share the ordinary Lua source fragment `examples/workflows/novel_context.lua`. The trusted host prepends the fragment and one newline before registration; the combined bytes are the executable source and receive one exact source hash. Composition only reads bytes; neither fragment executes before registration and workflow execution. The fragment defines the local evidence gate; no dynamic import or additional runtime authority is needed. Register each package as follows, using your pinned capability map:

```lua
local function read(path)
 local file=assert(io.open(path,'rb'))
 local bytes=file:read('*a');file:close();return bytes
end
local kind='character'
local source=read('examples/workflows/novel_context.lua')..'\n'
 ..read('examples/workflows/novel_'..kind..'.lua')
assert(workflow.register{id='novel.'..kind,version='1',source=source,
 source_hash=workflow.hash(source),capabilities=pins})
```

Changing the fragment or domain source changes the registered hash; publish a new workflow version for either change. The domain files are source fragments, not independently executable packages. Start with injected `scope`, `config`, and `evidence`. Every workflow wraps local reasoning in `ctx:step`; retrieval uses `ctx:resolve`. Source hashes, provider revisions, resolutions and capability outcomes are recorded by the existing runtime.

`scope` contains nonempty string `novel`, `corpus`, and `revision`. Names are display information: character identity is a separate `config.character_id`. An evidence provider receives `{kind,scope,config,step_id}` and returns `{available=true,scope,source_refs,...}`. Use `{revision='adapter-version',cache='none',resolve=function(ctx,request) ... end}` to resolve current data through `ctx:call` and a pinned read capability. Supply `source_revisions.evidence` when starting. Concrete values and ordinary provider functions are also supported by the context API. Providers are trusted adapters, responsible for obtaining scoped source evidence and reporting their coverage honestly. No external account, model or Gestalt daemon is required. A Gestalt/local-memory adapter can implement the same provider contract.

An unavailable provider produces an artifact with `status='unavailable'`, separate from an empty available assertion set. Scope mismatch produces `status='scope_mismatch'` without incorporating the foreign material. Outcomes retain requested scope, resolution provenance and available source references. The runtime may still terminate an uncertain capability invocation as uncertain. Never interpret successful artifact construction as complete evidence coverage or canon authority.

## Character

Evidence contains `assertions={{character_id,attribute,value,source_refs,scope?},...}`. Values are strings, allowing detailed descriptions and competing statements. Only the requested character ID is considered. A supplied assertion scope must match all three scope fields; malformed or mismatched matching-character assertions are exposed in `rejected`, not merged. Each attribute retains every supported assertion. Distinct values yield `status='contradictory'` and a sourced `conflicts` entry; repeated identical values do not fabricate a conflict. Requested `config.attributes` with no assertion get `status='absent'`. Absence means absent from the provided evidence, never a claim of nonexistence. `coverage` is `provided_assertions_only` or `incomplete`.

## Timeline

Evidence contains `events={{id,...},...}` with unique IDs and `constraints={{before,after,source_refs},...}`. Constraints assert strict precedence. Local Lua computes deterministic, sorted Kahn `layers` for the acyclic portion; peers in one layer are unrelated, not necessarily simultaneous. `unordered` contains cycle-blocked events, including downstream events. Cycle conflicts retain only genuinely cyclic edges and their sources; unknown endpoints produce `unknown_event` conflicts. Original events and constraints remain in the artifact. Supplied date fields are uninterpreted evidence; this workflow does not parse calendar dates or infer their order. Missing dates remain missing. Cycles and partial order remain review material, never newly invented chronology.

## Cleanup

Evidence contains `text`. Default cleanup normalizes CRLF to LF and removes trailing ASCII space/tab from each line and at EOF. It does not alter interior whitespace, punctuation, case, paragraph boundaries or lone carriage returns. It returns `original`, `proposed`, a line-indexed `diff` containing before/after strings, `source_revision`, `checks`, and `fact_checks`. Diff entries are replacement/addition/removal records rather than a unified patch. No write capability is invoked; `applied=false`, `proposal=true`, and `review_required=true` always apply.

`config.facts` is a list of nonempty literal assertions whose occurrence counts must survive. `changed_facts` counts changed supplied literals that occurred in the original; absent original literals are explicitly unavailable. Tests separately assert synthetic narrative facts. `checks.formatting_only` compares both texts under the documented normalization; `fact_preserving` means this narrow formatting-equivalence check passed and supplied literal checks did not change or lack evidence. This is not a general semantic verifier: literal agreement alone cannot prove arbitrary text equivalent, and formatting may matter artistically (verse, intentional trailing whitespace). `fact_coverage` records the limits. Optional `config.proposed_text` accepts a review proposal, including model output; any change beyond formatting sets `semantic_status='unverified'` and `fact_preserving=false`, even if all supplied literals survive. Zero changed literals in such a proposal does not prove zero changed narrative facts.

## Word counting rule `novel-words-v1`

The input must be valid UTF-8; otherwise return `status='invalid_utf8'` with the first invalid byte offset and no count. The exact embedded interval tables use Unicode 13.0.0 general categories, generated from Python `unicodedata` (version recorded in source and `unicode_version` in output). Generation scans `range(0x110000)` and merges adjacent scalars with `unicodedata.category(chr(cp))[0]` in `LN` or `M` respectively. Tables are pure source data; binary-search membership and token logic execute in Lua without any host Unicode dependency. This is a category-based convention, not UAX #29 linguistic segmentation.

- Letters (`L*`) and numbers (`N*`) start/extend tokens, including Arabic, Indic, supplementary CJK and numeric characters. Unassigned scalars in the pinned Unicode version delimit; newer assigned characters require a rule/table revision.
- Marks (`M*`) extend an existing token, never start one. Composed and decomposed spellings each form one token; no Unicode normalization is performed.
- ASCII apostrophe, U+2019, ASCII hyphen and U+2010 join tokens only after a current token and immediately before a letter/number. Leading, trailing, doubled and repeated joiners separate tokens. `don't`, `O’Neil` and `mother-in-law` count as one each; `rock--roll` counts as two. A mark immediately after a joiner does not satisfy this lookahead.
- All other categories delimit, including whitespace, NBSP, emoji, em dash, punctuation (including Greek question mark), symbols, format controls and unassigned code points. CJK counts contiguous letter/number runs, not dictionary words.
- Numeric runs count as words; letters and digits can share a token. Decimal punctuation splits, so `4.5` counts two. A leading combining mark is discarded as a delimiter; an internal mark extends the token.

The count artifact retains the rule identifier, source revision and evidence references.

## Isolated fixture and verification

Follow the repository [build prerequisites and platform instructions](../../README.md#build), then run the registered suites from the repository root:

```sh
cmake -S . -B build
cmake --build build --target boggart
env -u NO_COLOR ctest --test-dir build --output-on-failure -R '^(workflow_novel|workflow)$'
```

CTest supplies a throwaway profile for each suite. Fixtures never touch real manuscripts. For independent probes in an isolated process:

```lua
NOVEL_FIXTURE_ONLY=true
local f=assert(loadfile('tests/workflow_novel.lua'))()()
f.envelope('wordcount',{text="Ada's sea-going boat"})
local snapshot=f.run('wordcount')
assert(snapshot.result.count==3)
```

`f.scope(novel,revision)` creates a synthetic corpus scope. `f.envelope(kind,data,scope)` supplies a mutable response; `f.responses`, `f.unavailable`, `f.calls` expose responses/failure/counters. An optional `f.read(request)` host adapter replaces response lookup after the call counter and unavailability check, allowing isolated local-memory integration. `f.run(kind,config,scope,authority)` resolves a fresh provider under the specified current authority and returns the real source workflow snapshot. Use one fixture instance per isolated process because registrations are versioned and unique.

These authored examples qualify workflow/context/capability execution and domain artifacts. They do not qualify automatic mining, compiler coverage, promotion, restart durability or general semantic verification; full-cycle qualification belongs to BRAIN-39.
