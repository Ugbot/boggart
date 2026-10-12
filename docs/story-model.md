# The story model — design

Status: **proposal for review, revision 2**. It now takes in a survey of
research, commercial tools and practitioners (see "What the field says").
Nothing here is built yet beyond the file index, the style checks and the
line-by-line drafting from the P1/P2 work.

**Code:** the `story` module, `lua/story/`. It is pure Lua, with no C of its
own, and uses only what the core offers everyone: SQLite with FTS5, `sys.*`,
`git.checkpoint` and the model transport. The rest of boggart reaches it only
through `require("story")`, which exposes `register` (the tool), `command`
(`/story`) and `cli` (`boggart story`). Boot loads it under `pcall`, so a
broken or removed module costs `/story` and nothing else. It can be overlaid
file by file from `~/.boggart/lua/story/`.

## Why this exists

Writing a book with boggart is a multi-step process:

1. invent the story together;
2. lay out the beats and events;
3. write the prose;
4. edit and lengthen it;
5. fix plot holes.

The thing that breaks, at every step, is **consistency and lore**: facts that
drift, characters who know things too early, threads that go nowhere,
revisions that quietly lose events.

This design takes what four generations of story engines learned and turns it
into one model that every step reads from and writes to.

| Engine | What it contributes |
|---|---|
| Story Engine 1 (2024, Python) | events as world-state deltas; timelines built from actions |
| Story Engine 2 (Python, SQLite + FTS5) | the write → extract round-trip; FTS5 with sync triggers; context budgets; the *HPMOR* extraction lessons |
| web-serial (2025, FastAPI) | relationships as values changed by events; scenes as prose over an explicit list of events; plot twists with setup and payoff; enrichment that asks for "facts, not prose" |
| Story Engine 3 (Java, Postgres) | scene-ordered structure; typed beats that advance plots and arcs; knowledge fragments; state as of a scene; the prioritised context pack; author invariants; the interview ledger; the proposal gate; deterministic detectors with deduplicated findings |

Each engine also failed somewhere, and those failures are design inputs too:

- **SE2 had no entity resolution.** The *HPMOR* parse produced three Harrys
  and three Quirrells.
- **SE2 had no epistemic status.** A joke line was stored as the fact "Draco
  is carrying his baby".
- **SE2 lost updates.** It merged new state with `else: pass`, so changes were
  thrown away.
- **SE3's extractor never saw its own earlier output.** The known-entity list
  was always empty, and 156 characters came out of Dracula.
- **SE3 never wrote generated prose back into the model**, so each character's
  state went stale.
- **SE3's scenes in a chapter never saw each other's prose.**
- **SE3 had no canon / proposed / retconned status** on anything.

## Principles

1. **Two clocks.** Everything that happens has a **story time** (`t`: when
   it happens in the world; an ordinal, with an optional calendar such as
   "Day 3") and a **narrative position** (`pos`: where the book tells it;
   chapter, scene and line order).
   - What a *character* knows and what state the world is in are asked as of
     `t`.
   - What the *reader* knows, and what context is safe to show the drafter,
     are asked as of `pos`.
   - In a book told in order the two coincide, and in practice the second is
     just "as of chapter 7".
2. **Event-sourced world.** Entities and relationships are not rows we
   overwrite. Their state is the replay of **deltas** carried by events up to
   `ord`. There are no lost updates, and "what was true at chapter 7" is a
   query rather than a memory.
3. **Everything has a status and a source.** Every fact, delta and piece of
   knowledge is `proposed`, `canon`, `retconned` or `open_by_design`, and says
   where it came from:
   - the author;
   - the interview;
   - extraction from a file and line;
   - generation.

   It also carries a **modality**: true, claimed by someone, rumoured, a
   character's belief, or a joke. **Canon changes only by confirming a
   proposal.**
4. **Write → extract, always.** Any prose, whether the AI wrote it or you
   edited it, goes back through the same extractor. The result is compared
   with the plan and with canon, and every difference becomes a proposal or a
   finding. Prose and model can't silently diverge.
5. **Bounded context, assembled as of a point.** Every generation step gets a
   prioritised packet built from the model, never a growing chat and never
   whole-file rereads.
6. **Prose stays Markdown in the book's git repo.** The model lives in SQLite
   (FTS5/BM25 over everything textual) and is **mirrored to committed JSONL**
   in the book (`.boggart/story/*.jsonl`, canonical and diffable, the
   tracker's pattern). Deleting `boggart.db` loses nothing. Readable views (a
   story bible, character sheets as of chapter N, a timeline) are *generated*
   from it.

## What the field says (surveyed September 2026)

Three surveys fed this revision: the research literature, the commercial
tools, and practitioners who ship books with AI. On the big questions they
agree.

**Well supported. Keep these:**

- **Explicit, time-indexed story state, not a long context window.** The
  closest published systems (DOME, ConWriter, the Narrative World Model
  preprint) all keep explicit state. The best shipped practice does too:
  Claude-Book's fixed bible, per-chapter snapshots and append-only timeline,
  and NovelCrafter's "progressions".
  - Long context fails at novel length. On NoCha (true/false claims about
    whole novels) the best model scored 55.8% against about 97% for humans.
    Fiction.LiveBench shows comprehension dropping well before the maximum
    window.
  - "Lost in the middle" argues for a small, deliberately ordered packet.
- **Per-character knowledge, tracked symbolically.**
  - SymbolicToM: explicit belief graphs beat asking the model.
  - ConStory-Bench lists knowledge inconsistency as its own error type.
  - Practitioners name the knowledge leak (a character acting on something
    they haven't been told) as the single most valuable continuity check.
- **Deterministic checks over structured state, not an LLM reading the
  book.**
  - FlawedFictions: LLMs do poorly at finding plot holes however hard they
    reason, and worse as stories get longer. LLM-written stories have twice
    as many plot holes as human ones.
  - The commercial "manuscript analysers" invent plot points or contradict
    themselves.
  - The one tool that reliably catches errors (story-skills) runs
    deterministic checks over state files.
- **Extract, pair, show the evidence.** ConStory's checker extracts facts,
  pairs contradictions and builds an evidence chain. It reached precision
  0.88, but **recall only 0.55**.
- **Detailed outlines help** (DOC).
- **Replace form-filling with extraction.** NovelCrafter's Codex is
  "powerful but a time sink". The tools that fixed this (Sudowrite's
  braindump, AI Dungeon's auto Story Cards, webnovel-harness's upsert after
  acceptance) generate or extract the entries.

**Warnings that change this design:**

1. **Nobody writes one paragraph per call.** Shipping tools and practitioners
   settle on a beat or a few beats per call, about 400–800 words.
   - Rhythm, pace variation and the scene's arc live above the paragraph.
   - "AI doesn't vary pace" is a top complaint.
   - There is no evidence either way at paragraph level. → Keep the
     one-line-per-paragraph *plan*, but by default **write a beat per call**
     with its lines as the brief, and use paragraph-level calls for fixes.
     Measure both (below).
2. **Extraction is itself an LLM, and it misses things** (ConStory recall
   0.55). → Extracted items always land as `proposed`, with a confidence and
   an evidence quote. Detectors are only as good as extraction, so their
   recall must be measured, not assumed.
3. **Revision passes drift and cut.**
   - "LLM as a Broken Telephone": distortion builds up with each pass.
   - Four professional editors watched ChatGPT strip imagery, spell out
     subtext and make the key image literal.
   - A team's 6,000-word scenes came back at 1,500 words.

   → Revisions are **named operations that produce diffs** (never "improve
   this"). They carry the plan and canon as hard constraints. Words and
   events are counted on every output. A revision that drops a confirmed
   event is **auto-rejected**, and loops are capped at 3.
4. **Structure belongs in the state and the checkers, not the prose
   prompt.**
   - Over-detailed style guides make prose stilted.
   - JSON output shortens responses.

   → The drafter gets prose-shaped input: a short brief, a sample passage,
   a voice anchor per character, and the knowledge slice for this POV and
   point. It never gets a schema dump.
5. **The maintenance tax kills story bibles.** If canon only advances by
   manual confirmation, authors stop confirming. → Proposals come in batches
   and are cheap to accept. You chose always-ask, so the design makes
   confirming cheap instead: grouped batches, with plan matches marked.
6. **Don't judge quality with an LLM, and don't let the drafter mark its own
   homework.**
   - LLM judges don't correlate with experts on literary quality (TTCW).
   - Self-review is biased.

   → LLM checks ask only specific, answerable questions ("is this claim
   contradicted by these facts?"), in a separate fresh context.
7. **Multi-agent is mostly hype as a *cause* of consistency.** What helps is
   decomposition plus explicit state. Agents are optional; the store is not.

**What we were missing (now added below):**

- **Two clocks.** When an event happens in the story (story time) is not
  when the book reveals it (narrative position). Flashbacks, frame stories
  and reveal order need both. This comes from Aeon Timeline and the
  Narrative World Model.
- **The reader as a knowledge holder**, for dramatic irony, foreshadowing and
  payoff, and to stop a twist leaking.
- **Promises, questions and clues as entities** (story-skills), plus an
  **exemptions ledger** for deliberate breaks.
- **Withheld canon.** A twist can be canon and still be kept out of drafting
  context until it's time (NovelCrafter "Never include", World Anvil
  secrets).
- **Deterministic, tiered context selection with an inspector.** Every item
  in the packet shows why it's there and what it cost (NovelAI's Context
  Viewer is the most-praised debugging aid). The tools also learned to match
  aliases with exclusion lists, to cap each item's budget, and to include
  less rather than more.
- **A cache-friendly prompt layout.** Stable style, voice and bible go first,
  byte-identical on every call; the append-only recent prose next; the brief
  last. webnovel-harness reports about 10% of the uncached cost by chapter
  30.
- **Dynamic anti-slop.** Mine the model's own repeated phrases from each
  chapter into the ban list for the next (HN pipeline, EQ-Bench slop score),
  plus the LAMP quality categories: cliché, over-exposition, spelled-out
  subtext.
- **Where to look hardest.** Errors cluster at 40–60% of a story and in
  high-entropy spans (ConStory): check the middle more, and use logprobs
  where the wire gives them.
- **Measurement.** Run a ConStory-Bench harness and FlawedFictions-style
  injected contradictions to measure detector recall, and EQ-Bench-style
  slop and degradation metrics to settle the paragraph-vs-beat question on
  evidence.
- **Voice.** Fine-tuning on the author's own prose is the one proven fix for
  voice drift and AI tells: prompted imitation was flagged as AI 97% of the
  time, fine-tuned 3%. It stays on the roadmap as the alternative to ever
  more prompting.
- **Long context for reading, not remembering.** Whole-draft reads (a
  developmental pass, a beta read) are a legitimate use. Memory for drafting
  is not.

## The model

### Structure: how the story is broken down

| Table | Holds |
|---|---|
| `st_story` | title, premise, genre, narration (person/tense), style file, status |
| `st_thread` | a plot, subplot, character arc, mystery or romance. Fields: kind, title, owner character, conflict, stakes, objective, status, phase |
| `st_chapter` | ord, title, card (one line), summary, status (card, outlined, drafted, revised, done), file path |
| `st_scene` | chapter, **pos** (narrative order), **t** (story time; differs for flashbacks), title, summary, POV character, cast present, place, time label or calendar, POV goal, entry and exit hooks, tone, status |
| `st_beat` | scene, ord, kind, importance, text (one line) |
| `st_beat_thread` | beat × thread: what the beat does to it (establishes, complicates, reveals, reverses, resolves…) and its significance for that thread |
| `st_line` | beat, ord, text (one line per paragraph), done, prose anchor |

**Beat kinds** are SE3's list: hook, inciting, midpoint, crisis, climax,
revelation, reversal, foreshadowing, callback, decision, transition, and so on.

**Importance** runs from minor to climactic, and scales the target length.

**Prose anchors.** Each paragraph in the Markdown carries an invisible anchor
back to its line (`<!-- l:3.2 -->`, stripped on export). So any paragraph can
be re-expanded, edited or checked against the line it was written from.
Today's `redo` can only touch the last paragraph; anchors lift that limit.

### World, events and state

| Table | Holds |
|---|---|
| `st_entity` | kind (character, place, item, faction, group), canonical name, parent (the place tree, faction tree), discoverability (public, local, hidden, secret), profile text, attributes (voice samples, psychology, tropes) |
| `st_alias` | alias → entity, and how it was learned. **Resolution happens before any insert.** |
| `st_event` | t (story time), pos (where it is told), scene, beat, kind, one-line summary, is_secret, source span (file and line), confidence |
| `st_delta` | event → entity: `create`, `set field=value`, `move to place`, `acquire`/`lose item`, `relation a↔b field ±value`, `end` (death, destruction) |
| `st_event_link` | cause → effect |
| `st_rule` | world rules: magic system limits, technology level, social structure. Checkable, and in every prompt. |

**State as of `ord`** is the fold of the deltas up to that point: where each
character is, whether they're alive, what they carry, their relationships as
numbers and their history. Presence becomes checkable, e.g. "who is where"
answers "can X be here then?"

### Facts and knowledge: what is true, and who knows it

| Table | Holds |
|---|---|
| `st_fact` | kind (lore, history, rule, invariant), subject entity, body, visibility (public or secret), **status** (proposed, canon, retconned, open_by_design), **modality** (true, claimed, rumour, belief, joke), holder (for claims and beliefs), valid from/to ord, superseded_by, source, importance |
| `st_knows` | holder × fact: learned at `t` (for a character) or `pos` (for **the reader**, a holder in its own right), how (witnessed, told, read, inferred, rumour), from whom, confidence, **their version** (which may be wrong), superseded_by |

- **Invariants** are how-to-write rules ("close third, past tense", "no
  modern diction"). They go into every prompt.
- **`open_by_design`** marks mysteries you deliberately leave open. They are
  never "resolved" by the model.
- **`withhold_until`** (a `pos`) keeps a canon fact, such as the twist, out of
  every drafting packet until the book reaches that point, even though it is
  canon.

Two queries do most of the work:
- **Knowledge as of `ord`**: what the POV character knows, *and what they do
  not yet know*. That's the leak guard.
- **Who knows a given fact, and since when.**

### Promises, findings and the process

| Table | Holds |
|---|---|
| `st_promise` | kind (promise, question, clue, Chekhov item), setup (beat or fact), payoff (beat, null while open), thread, status (open, paid, open_by_design), due by (pos) |
| `st_exemption` | a deliberate break the detectors must accept (a flashback, an unreliable narrator's lie), with the reason |
| `st_finding` | kind (leak, contradiction, plothole, unpaid promise, Chekhov, arc plateau, lost event, hygiene), severity, status, anchor (scene, line or entity), dedup key. It auto-resolves when the cause goes away, and a dismissal survives rebuilds. |
| `st_proposal` | a pending change to canon (fact, delta, entity, alias, knowledge, structure). Fields: payload, **evidence** (file:line quote; a quote that can't be found auto-rejects), origin, status |
| `st_dimension` / `st_assumption` | the interview ledger (premise, tone, cast, world, structure, stakes) → unknown, vague, solid, locked, open_by_design; plus assumptions awaiting confirmation |
| `st_summary` | per scene and per chapter, cached by content hash. They build up hierarchically: scenes → chapter → act. They never overwrite (SE2's compression bug). |
| `st_change` | before/after for every confirmed change, for undo |

**Context selection is deterministic and tiered**, and every item records
why it was picked:

1. always (invariants, style, voice);
2. pinned to this scene;
3. this scene's cast and place;
4. detected by alias, with exclusion lists and case rules;
5. one hop of relations;
6. BM25 retrieval over event and fact summaries, for recall.

Each tier has a budget. `/story context <scene>` is the **inspector**: every
item, its reason, its cost, and what was trimmed.

**FTS5 with BM25** runs over prose (per paragraph, with anchors), entity
profiles, facts, knowledge, events and summaries, kept in sync by triggers
(SE2's pattern).

## The process, step by step, and what keeps each step consistent

### 1. Invent

The interview asks one question at a time, always aimed at the weakest
dimension that isn't locked. It never re-asks a locked or open-by-design
dimension. Answers become **proposals** you confirm: entities, facts, rules,
invariants and threads.

Vague answers become explicit assumptions ("I assumed X"), not silent
inventions. **Canon import** does the same from existing docs (your numbered
planning files and character sheets), using "extract only what the document
states, never invent", with a file:line reference for each item.

### 2. Structure

The structure is built in this order:
1. threads and arcs;
2. chapter cards, one line each;
3. scenes: POV, place, time and a summary;
4. beats: typed, with what each does to each thread;
5. **planned events** per scene, with their deltas ("Vera gets the key";
   "Moth learns of the debt").

Setup beats register promises.

Checks at this stage:
- **Planned deltas** are checked against state as of that point: moving a
  dead character, giving an item someone else holds, a character in two
  places at once.
- **Planned learning** is checked against knowledge: telling Moth something
  before anyone who could have told him knows it.

Plot holes get caught while they are still only lines.

### 3. Expand into prose

The plan goes beat → paragraph lines; **the default writing unit is a beat**
(about 400–800 words), with its paragraph lines as the brief and a fresh
call per beat, or per planned event when a beat holds several. Paragraph-level calls (what P2 built) stay for targeted fixes
and as an option. Which works better for you gets **measured** (slop,
degradation, events covered), not assumed.

The prompt is laid out for caching: invariants, style, voice samples and the
bible slice first, byte-identical across calls; then the recent prose; then
the brief. The drafter gets prose-shaped input and can **look up** the bible
with tools, never a schema dump. The packet is now assembled from the model as of
that point, in priority order:

1. The task and the line.
2. Invariants and hard rules.
3. The chapter's beats: done beats as the summary, later beats as the "don't
   get ahead" list.
4. This scene's **planned events**: the paragraph must cover them and invent
   none.
5. The last ~450 words, verbatim, including earlier scenes in the chapter
   (SE3 missed this).
6. **Cast state as of now**: where everyone is, what they hold, their
   relationships.
7. **POV knowledge, including an explicit "does NOT yet know" list.**
8. Rules and facts relevant to the line, found by BM25.
9. Promises due soon.
10. Summaries of earlier scenes and chapters.
11. The style guide.

Blocks are trimmed lowest-priority first, and the packet reports what was cut.

### 4. Write back

After each beat, the prose is extracted back into the model, by a separate
call in a fresh context: the drafter never checks its own work.
The extraction is **anchored**:
- an alias pre-sweep;
- known entities passed **by id**;
- new ones as `_new_`;
- known entities upserted per chunk, so they're known for the next chunk.

It produces events, deltas, facts and knowledge **as proposals with
evidence**, each with its modality ("Moth *claims* the debt was paid").

That output is then diffed against the plan and canon:
- **Planned event missing** → finding.
- **Unplanned new entity or event** → proposal.
- **Contradicts canon** → finding (a fact that conflicts with a canon fact on
  the same subject, which gets an LLM check).
- **POV used a fact they don't know yet** → leak finding.

**Word counts and events covered are checked on every output.** A beat
that comes back with fewer events than its brief is a failed step, the
"summarised instead of dramatised" failure.

**Confirmation policy (decided):** nothing enters canon without you.
- Everything extracted arrives as proposals, grouped by scene and kind.
- Proposals that match the plan are marked, so they're quick to accept.
- A batch can be accepted or rejected in one step, keeping the maintenance
  tax low.

### 5. Edit and lengthen

Revisions are **named operations that produce a diff you approve**, never
"improve this chapter". Each keeps the original. Operations act on a span of
anchored paragraphs:
- expand (develop the beat, add texture);
- tighten;
- voice;
- style-match;
- fix a finding.

Each carries **constraints from the model**:
- keep the events this span covers;
- keep knowledge as of this point, so no hindsight.

After the edit the span is re-extracted and diffed. **A revision that
drops a confirmed event is auto-rejected**, and self-critique loops are
capped at 3. That catches, at the level of meaning, the "revision shortened the
chapter" failure that ~/novel suffered. Lengthening then becomes planned: add
lines under a beat, or add a beat, and expand only those.

### 6. Fix plot holes

**Deterministic detectors** (SE3's, run on the model, fast):
- knowledge leak;
- contradiction (two owners of one item, one character in two places, a
  value changing with no delta);
- effect without cause;
- a character on stage before being introduced;
- unpaid promise (warns after N scenes);
- Chekhov item;
- arc plateau;
- thread stalled;
- timeline cycle;
- hygiene (TBDs, unparsable ledger lines).

**One LLM check SE3 never had**: new prose against the canon facts about the
entities it names. It is asked as a specific question with the facts
attached, in a fresh context, and must quote its evidence.

The middle of the book (40–60%) and high-uncertainty spans are checked more
heavily.

**Quality detectors**, separate from continuity, catch:
- the model's own repeated phrases, mined per chapter into a growing ban
  list;
- cliché;
- over-exposition;
- spelled-out subtext.

Every finding is anchored to a line or an entity. **Remediation** proposes
before and after text (or a model change) for you to approve.

### 7. Bring in the books you already have

Import is the same anchored extraction over existing chapters and planning
docs, with:
- chunking by chapter, then paragraph;
- known entities upserted per chunk (the SE3 bug fixed);
- alias resolution confirmed by BM25 plus a model yes/no;
- modality recorded;
- source spans kept.

Everything arrives as proposals, confirmed in bulk by category. The Six's
LOCKED memory rows and the quiet move's truth/knowledge ledger (`07-…`) map
straight onto facts and knowledge.

## How it surfaces

- **One `story` tool** with these nouns:
  - `book`, `chapter`, `scene`, `beat`, `line`
  - `thread`, `entity`, `fact`, `event`, `knows`
  - `promise`, `proposal`, `finding`
  - `interview`, `draft`, `edit`, `extract`, `search`

  Queries take `as_of=` (a chapter, scene or ord).
- **TUI `/story` views:**
  - bible
  - `char vera @7`
  - timeline
  - chapter navigator
  - findings
  - proposals (confirm or reject inline)
  - `context 7` (what the model would see)
- **Studio**: the same models on a Story tab.

## What stays from what is built

- **Stays:** the book manifest, the file index, the style engine, and the
  line-by-line expansion loop.
- **Moves into the model:** today's `.boggart/plans/chNN.md` becomes
  `st_scene`/`st_beat`/`st_line` rows, keeping a Markdown import/export so
  plans remain hand-editable.

## Measuring it

A `story bench` harness keeps the design honest:

- **ConStory-Bench prompts** score consistency errors per thousand words.
- **FlawedFictions-style injected contradictions** in a fixture book measure
  detector recall.
- **EQ-Bench-style slop and chapter-over-chapter degradation** compare
  beat-level and paragraph-level writing, and one model against another.

## Build order

| Phase | Delivers |
|---|---|
| M1 ✓ | **Built 2026-09-27** (`lua/story/model.lua`, `lua/story/world.lua`, `tests/story_model.lua`, 84 checks). Model core (two clocks, reader as a knowledge holder, promises, exemptions): the tables, alias resolution, deltas and state as of `ord`, facts/knowledge with status and modality, FTS5, the JSONL mirror, and the `story` nouns for them. Tests port SE3's state-as-of and knowledge tests plus SE2's lost-update and duplicate-alias cases. |
| M2 | Invent: the interview ledger, proposals, invariants and rules, and canon import from your planning docs. |
| M3 | Structure → expansion: scenes, beats, planned events and promises, checked against state at plan time; tiered context selection with the inspector; the cache-friendly layout; beat-level writing (paragraph as an option); prose anchors. |
| M4 | Write-back: anchored extraction after each write; the diff against plan and canon; proposals and findings; import of the three existing books. |
| M5 | Edit and lengthen as span operations with constraints; the detectors; remediation. |
| M6 | Views in the TUI and studio. |
| M7 | The `story bench` harness (ConStory, injected contradictions, slop and degradation). It can run any time after M4, and it settles the writing-unit question. |
| later | Fine-tuning on the author's prose for voice. |

## Decisions (made 2026-09-27)

1. **Truth lives in SQLite, mirrored to committed JSONL** in each book
   (`.boggart/story/*.jsonl`). Readable bibles and sheets are generated
   views, and prose stays Markdown.
2. **The drafting unit is a beat or a planned event per call.** The beat's
   one-line-per-paragraph plan is the brief. Paragraph calls are kept for
   fixes, and the bench compares the options.
3. **Nothing is confirmed without asking.** Every extracted fact, event,
   delta and piece of knowledge, planned or not, arrives as a proposal.
   - To keep the maintenance tax low, proposals are grouped (by scene, then
     kind), show their evidence, and can be accepted or rejected **in
     batches**.
   - Items that match the approved plan are marked as such, so they're the
     quick ones to accept.
4. **Spies (~/novel) is the first real book imported**, after the model is
   proven on fixture books.
