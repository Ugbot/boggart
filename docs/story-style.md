# Managing writing style — state of the art, and a redesign

Status: **built (S1–S6), 2026-09-27.** The code is in the `story` module
(`lua/story/`):
- `lint.lua`: the checker;
- `style.lua`: layers and sets;
- `sets.lua`: the built-in set library;
- `baseline.lua`;
- `slop.lua`;
- `decode.lua`;
- `stylecmd.lua`: the `style` noun;
- `draft.lua`: packet, candidates, picks.

Tests are in `tests/story_style.lua`. This document follows a
survey (September 2026) of research, commercial tools, decoding techniques
and practitioners.

## Where we are

Each book has a data-only `.boggart/style.lua` holding several kinds of rule:

- **numeric limits:** maximum sentence length, an average-sentence-length
  band, a "the way" budget, and same-opener runs;
- **word lists:** banned words and theme-stating "tells";
- **per-POV voice notes;**
- **simile and refrain caps;**
- **the guide itself:** a long prose style guide of about 13k characters,
  covering voice, sentence DNA, bans, diction, POV matrices, imagery, scene
  craft, exemplars and a self-check.

A deterministic checker reports PASS or ISSUE with line numbers, and some
checks can be marked advisory. The drafting packet pastes in the hard rules
(including the ban list) and the guide, capped at 25% of the budget.

What went wrong in practice:
- The model drifts off-voice.
- The prose came out "awful".
- The metrics fight the intended voice. Deliberate anaphora was flagged.
- One book's rules applied to another book did damage.

## What the field says

**1. Don't paste a long rule list into the drafting prompt.**

The chance a model follows *every* instruction falls roughly
multiplicatively with the number of instructions:
- "Curse of Instructions" (ICLR 2025): with 10 instructions, GPT-4o
  followed them all 15% of the time and Claude 3.5 44%.
- A 2026 study of 15 models and about 370k checks: reliability collapses
  past 5–6 simultaneous constraints. **Sentence-shape rules (length,
  structure) fail twice as fast as word rules.** Models favour instructions
  that come earlier in the prompt.

NovelCrafter warns of exactly our failure: "so many rules that writing
becomes mechanical… stilted prose". It advises flexible bounds ("shorter
sentences during action") over hard numbers.

→ Our 13k-character guide in every drafting call is close to the worst case.

**2. Naming banned words in the prompt may prime them.**

"Pink elephant" results show that naming a forbidden thing makes the model
more likely to produce it. The fix needs training, not prompting. This is
moderate evidence for prose.

→ Bans belong in the checker and the decoder, not the drafting prompt.

**3. Your own prose beats descriptions of it.**
- Few-shot examples gave up to 23.5× better style matching than zero-shot.
- **"Completion" framing, where the model continues the author's own text,
  reached 99.9% style agreement.**
- Prompt strategy mattered more than model size (arXiv 2509.24930).
- Sudowrite: "A prompt is a description of a thing. A sample is the thing."
  They advise 5–10 paragraphs covering a range (quiet, action, dialogue,
  interior), or a whole chapter.
- Andrew Mayne and Every's guide: *explain, then imitate*. Build the style
  analysis *from* the samples, and keep both. "One paired example teaches
  better than paragraphs of abstraction." Before/after pairs are the most
  valuable part of a guide.

**4. Models pull every voice back to their own.**
- LLM prose homogenises across models ("Idiosyncrasies in LLMs": a model can
  be identified from its text 97% of the time).
- Instruction tuning *reduces* creative uncertainty.
- **AI revision normalises voice in one fixed direction.** Across 300
  narratives × 3 models, every rewrite had fewer contractions, function
  words and first-person pronouns, and longer words with fancier
  punctuation. Voice-preserving prompts shrink the effect but never reverse
  it (van Nuenen 2026).
- A review saw GPT-5.5 revert to its assistant register around paragraph six
  of long generations.

→ Every AI edit must be measured against the *author's* baseline afterwards.
Don't trust the model to remember the voice.

**5. Metrics are trusted relative to the author, distrusted as absolutes.**

Practitioners distrust readability and grade-level tools for fiction.
Hemingway "cannot tell a clumsy sentence from a deliberate artistic choice".

They trust these, as reports rather than gates:
- counts of overused words and repeated phrases;
- sentence-length *variation*;
- stylometric drift against the author's own baseline.

A Slate piece (August 2026) describes a writer who policed every slop hit
and drifted "back toward the AI-generated median".

Research agrees: there is **no published method for measuring style drift
within one book**. It's an open gap, and we can lead on it.

**6. Enforcing tics at decode time works, but mostly locally.**

The Antislop work (ICLR 2026) found:
- Plain token banning becomes unusable at about 2,000 patterns.
- A **backtracking sampler**, which rewinds when a banned string or regex
  appears, suppresses 8,000+ patterns with quality intact.
- **FTPO** fine-tuning cuts slop by about 90% without the quality loss DPO
  causes.

Which backends can use decode-time controls:

| Backend | Controls |
|---|---|
| llama.cpp | `logit_bias` with string keys; DRY (repetition) and XTC (cliché) samplers; min-p; GBNF grammars. It has no phrase backtracking, so we would add a boggart-side loop. |
| OpenAI, DeepSeek | Token-id `logit_bias`, and only outside reasoning or thinking modes. |
| Anthropic | Nothing at the decode level. |

→ Two tiers: backtracking on local models; on API models, check and then
regenerate only the offending span.

**7. Generate several, rank, keep what the author picks.**

"AI-Slop to AI-Polish" (2025): generating several candidates and ranking them
with a quality reward model trained on professional edits beats
self-revision, and experts agreed. Its LAMP corpus gives a taxonomy of AI
idiosyncrasies (cliché, unnecessary exposition, purple prose, spelled-out
subtext…).

→ Log which candidate the author picks and what they edit. That becomes our
own preference data.

**8. Fine-tuning on the author's prose is the strongest lever, but narrow.**
- Fine-tuning ChatGPT on each of 50 authors' complete works dropped AI
  detection from 97% to 3%, and experts preferred the output for stylistic
  fidelity (Chakrabarty et al. 2025).
- The catch is size: it used whole published corpora and was tested on
  roughly 450-word excerpts.
- A LoRA needs about 1M+ tokens of the author's clean prose.
- OpenAI is winding down self-serve fine-tuning, with new jobs ending
  2027-01-06, and Anthropic offers none.

→ A local LoRA is optional, for an author with a large back catalogue.
FTPO-style tic suppression on a local model is the realistic fine-tune.

**9. Style belongs to the book.** Every tool keys style to the project.
Metrics relative to a baseline make one book's baseline and allow-list
simply wrong for another. A series inherits only by explicit copy.

## The redesign

Split what is now one blob into **five layers**, each with its own path:

| Layer | Holds | Goes into drafting? | Enforced by |
|---|---|---|---|
| **exemplars** | The author's own passages from this book, 300–600 words each, tagged by POV and mode (action, interior, dialogue, quiet). Plus before/after pairs. A "golden" set chosen by the author, plus approved chapters as they accumulate. | **Yes, the main signal.** 2–4 chosen per beat by POV and mode, varied rather than matched on content. | — |
| **voice card** | At most about 5 positive lines of voice and 1–2 lines per POV, written as an *analysis of the exemplars* ("explain, then imitate"). Flexible bounds, no numbers. | Yes, first in the prompt, short | — |
| **rules** | Checks, Vale-style (below): banned words, tells, repetition, consistency, metrics | **No.** Nothing numeric or banned in the drafting prompt. | the checker, then targeted regeneration |
| **baseline** | The author's stylometric fingerprint, measured from approved prose (below) | No | the drift report |
| **decode** | Per-backend controls: phrase bans, DRY/XTC/min-p settings | No (it's sampler state) | the local backtracking sampler, or API check-and-regenerate |

The **long guide** (sentence DNA, imagery, scene craft…) stays, as reference
for the **reviser and critic** roles. When a check fails, only the section
for that rule is handed to the regeneration.

### The checker, rebuilt on Vale's rule model

Each rule has an id, a type, a scope and a severity:

```lua
{ id = "Book.TheWay", type = "occurrence", scope = "chapter", max = 3, level = "warning",
  message = "'the way' comparisons: {n} (budget {max}); each must come from the POV's trade" }
```

**Types:**
- `existence`: banned words, tells;
- `substitution`: X → prefer Y;
- `occurrence`: min/max per scope (simile budget, refrains);
- `repetition`: same-opener runs, repeated n-grams;
- `consistency`: two spellings of one name in a chapter;
- `conditional`: X without its required Y;
- `metric`: a statistic against the baseline.

**Levels:** `suggestion`, `warning`, `error`. **Only `error` fails.** Most
voice rules are warnings; true slop tells and anachronisms are errors.

**Suppression:**
- Inline in the manuscript: `<!-- style off: Book.Anaphora -->` …
  `<!-- style on -->`. It is stripped on export, and every suppression is
  listed in the report.
- A per-book **allow-list of deliberate devices** (anaphora, fragments,
  polysyndeton) turns those checks into notes.

**Slop pack:**
- A versioned rule pack of LLM tells, seeded from EQ-Bench and Antislop:
  not-X-but-Y regexes, "a testament to", tapestry, ghosts and whispers,
  forced synaesthesia, rule-of-three, moral endings.
- It is pruned per book and **grows from data**. N-grams over-represented in
  drafts, relative to the author's own chapters (the Antislop method), are
  *proposed* as new rules for the author to accept. This follows the
  proposal pattern the story model already uses.

### Baseline and drift (the open gap)

The baseline is measured per book, and per POV where there's enough text,
from approved chapters or the golden exemplars. It covers:
- sentence-length *distribution* (not just the mean);
- function-word and pronoun rates;
- contractions;
- punctuation rates (em dash, semicolon, ellipsis);
- paragraph length;
- dialogue share;
- opener variety;
- the over-represented n-gram profile.

Every chapter and every AI edit gets a **drift report**: which markers moved,
and by how much against the author's own chapter-to-chapter spread ("2σ fewer
contractions than your chapters"). Two things are gated on it:
- An AI revision that moves the voice in van Nuenen's normalising direction
  past a threshold is flagged, and the diff is shown.
- When several drafts of a chapter drift the same way, its prompts
  re-anchor: fresh exemplars, plus the last approved passage *only if it
  passed*, so drift doesn't compound.

A style-embedding distance (LUAR or StyleDistance) is a later addition. The
plain stylometric markers come first, because they're explainable and need
no model.

### Drafting and editing flow

1. **Draft:**
   - Prompt order: the voice card, then 2–4 exemplars, then the brief.
   - Use completion framing where the backend allows it: on local models,
     present the context as the manuscript continuing; on API models, put the
     exemplars right before the generation point.
   - Local models: phrase backtracking, plus DRY (about 0.8), min-p
     (0.02–0.05) and optional XTC.
2. **Check:** run the rules and the drift report.
   - An `error` regenerates only the offending span, with that rule's message
     and its guide section.
   - Warnings are reported.
3. **Candidates:** optionally generate *n* per beat, ranked by errors, then
   drift distance, then an LLM judge prompted with LAMP's categories. **The
   author's choice and edits are logged** as preference data.
4. **Edit passes** are named operations (de-slop, tighten, voice) that
   **flag rather than rewrite** by default. Any rewrite is measured against
   the baseline before it's offered.
5. **Per-character dialogue sheets:** each has 2–3 real lines and a diction
   note. They're injected only for characters present, and later measured
   for distinctness.

### Fine-tuning (phase 2, local only)

- **With 1M+ tokens of the author's prose:** a LoRA on continuation pairs.
- **Otherwise:** FTPO-style tic suppression on a local model, trained on the
  checker's own findings and the author's picks.
- **Not built on OpenAI or Anthropic fine-tuning.** OpenAI is winding it
  down, and Anthropic has none for current models.
- Only the author's own writing is used.

## What changes in the three books

- **~/novel:** the 13k guide becomes reference material.
  - The voice card is distilled from §1 and §5 plus the exemplars in §8,
    which are already real passages.
  - Its numeric limits become `metric` and `occurrence` warnings.
  - Its "advisory" list (chains, anaphora, avg_min) becomes the allow-list.
- **The Six:** the voice, simile and refrain rules map directly. Its
  "confusion before recognition" register is guide material.
- **The quiet move:** it has no style file yet. Its em-dash ban becomes an
  `existence` error, and its exemplars come from the prologue.

## Sets (person, tense, per book, per POV)

A **set** is a named variation of the style, such as `third-past`,
`first-present` or a book's own `moth-first`.
- **What it carries:** narration (person and tense), voice lines, exemplars
  (by `set:` tag), rules (overriding by id), allow-list additions and decode
  settings.
- **Inheritance:** it `extends` another set.
- **Where a named set is looked up:**
  1. the book's inline `sets`;
  2. `<book>/.boggart/style/sets/<name>.lua`;
  3. `~/.boggart/style/sets/<name>.lua`;
  4. the built-in library: `first-past`, `first-present`, `third-past`,
     `third-present`, `third-omniscient`, `second-present`, `documents`.
- **How a chapter gets its set:** the plan's `style:` (`plan set ... set=`),
  else the POV's `pov_sets` entry, else the book's `default_set`.
- **Precedence:** a set's narration wins over the book's base. Library sets
  hold only what is true of the mode itself (the narration line, person and
  tense checks), never a book's voice.

## Build order

| Step | Delivers |
|---|---|
| S1 | Layered style file (exemplars, voice card, rules, allow-list), the Vale-style checker with levels and suppression, and the drafting packet change: voice card and exemplars in, rules and bans out. Migrate the three books. |
| S2 | Baseline plus drift report, run on every chapter and every AI edit. |
| S3 | Slop pack, with data-grown proposals. |
| S4 | Decoding: the llama.cpp backtracking loop and sampler settings; check-and-regenerate the span on API models. |
| S5 | Candidates plus ranking, with author picks and edits logged. |
| S6 | Local fine-tuning: LoRA or FTPO. |

## Sources (selected)

**Instruction limits**
- Curse of Instructions (ICLR 2025)
- IFScale, arXiv 2507.11538
- arXiv 2608.12426
- Pink Elephants, arXiv 2402.07896

**Imitation, homogenisation and fine-tuning**
- arXiv 2509.24930
- arXiv 2509.14543
- Chakrabarty et al., arXiv 2510.13939
- van Nuenen, arXiv 2604.22142
- Idiosyncrasies in LLMs, arXiv 2502.12150

**Slop and editing**
- Antislop / FTPO, arXiv 2510.15061
- LAMP, arXiv 2409.14509
- AI-Slop to AI-Polish, arXiv 2504.07532
- EQ-Bench slop score

**Tools and practitioners**
- Vale documentation
- llama.cpp server README
- NovelCrafter "effective style entries"
- Sudowrite voice matching
- Every's AI style guide
- Andrew Mayne
- Slate, August 2026
