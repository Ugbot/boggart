# boggart — UX review

**Snapshot: 2026-09-04.** A hands-on pass over both surfaces: a genuinely fresh
install of the CLI, and the studio driven and photographed. Findings are ordered
by how much they cost a person, not by how hard they are to fix. Everything here
was observed, not inferred; where something was fixed in this pass it says so.

Companion documents: [`tui-quality.md`](./tui-quality.md) is the observable
pass/fail bar, [`tui-complete.md`](./tui-complete.md) the cTUI backlog,
[`studio-review.md`](./studio-review.md) the studio ticket list,
[`peers.md`](./peers.md) how the product surface compares. This file is the
*experience*: what it is like to arrive at boggart and try to use it.

---

## The one-sentence verdict

The machinery is far ahead of the invitation. Every individual surface is
competent — the composer, the permission bar, doctor, the fleet dashboard — but
the first ten minutes give a new user a blank canvas, three different sets of
instructions that disagree, and no answer to "what do I do now?". That gap is
what "a bit ropy" is describing.

---

## 1. Fixed in this pass

### 1.1 A doomed first request, and a raw 401 — **the worst one**

On a fresh install with no key, typing anything produced:

```
The API rejected our credentials (HTTP 401).
Detail: {"type":"error","error":{"type":"authentication_error",
"message":"x-api-key header is required"},"request_id":"req_011Cei..."}
```

A network round trip that could not succeed, answered with the provider's raw
JSON. There *is* a credential pre-flight in `api.lua` that says the right thing
("No API credentials found", with the three ways to fix it) — but the routing
work had made `auth_headers()` return early whenever a request carried a route,
which is now every request. **The pre-flight had stopped running.** A regression
introduced two commits earlier, found only by using the thing.

Now: no request is sent, and the message names the provider and its environment
variable, and points at the catalog.

```
No credentials for anthropic.
  /auth key <key> anthropic
  export ANTHROPIC_API_KEY=...
`boggart models` lists every provider and which ones have a key.
```

### 1.2 The first line a new user read was database housekeeping

`· model catalog seeded: 16 providers, 17 models` printed *above* the welcome
banner. Silent now; the `catalog:import` event still carries the counts.

### 1.3 Three sets of first-run instructions that disagreed

The CLI welcome said `/auth key`. The studio's Welcome tab offered two buttons.
The studio's agent view — the tab next to it — said "Command palette: 'agent:
set api key'… or 'agent: set endpoint' for a local server (ds4 on :8000)",
sending someone to a palette incantation and one niche local server while a
Welcome tab with buttons sat visibly beside it. The agent view now names the
visible thing first and mentions that sixteen providers are known.

### 1.4 `/help` was a forty-line wall

One flat list, no order a person could predict. Grouped now — *the
conversation*, *model and credentials*, *what it may do*, *running work*,
*git*, *the harness itself* — with anything ungrouped still listed under *more*,
and a test asserting every command appears somewhere so one can never be added
and silently vanish.

### 1.5 The catalog was invisible from the REPL

`boggart models` (CLI) and Agent ▸ Models… (studio) both existed; the REPL had
neither, and `/model`'s list was still built from the *pre-catalog* provider
table — so the same install offered different models depending on which surface
you asked. `/models` now shows the catalog, and `/model` lists from it.

### 1.6 `doctor` knew nothing about the catalog

It reports paths, store, credentials, MCP and overlays — and, now, how many
providers are known, **how many have a key**, and what each role points at, with
a warning when none are usable.

### 1.7 "Reply to boggart…" on an empty chat

The composer asked you to reply to a conversation that had not started. An empty
chat now asks for the thing you are there to do.

---

## 2. Not fixed — ranked, with the reasoning

### 2.1 The agent view has no "what now?" — *biggest remaining item*

The default workspace is a header of key hints, then **roughly 500 px of
nothing**, then the composer. Nothing suggests a first move. Every other empty
state in the app is better than the one people see first: FLEET says "(no swarm
running — ask the chat to spawn, or New task)"; the recents rail says "No
sessions yet".

The fix is a first-run panel in that dead space: three or four *runnable*
suggestions drawn from what is actually here — "explain this repository",
"review my uncommitted changes", "add a tool for…" — each one click. It is the
difference between a blank canvas and an invitation, and boggart has an unusual
advantage to show off: the agent can write its own tools and panels, and nothing
in the first-run experience says so.

Deferred because it is a design task, not a bug: the suggestions need to be
genuinely useful and repo-aware, or they become noise to dismiss.

### 2.2 Three ways to start a new chat, none of them primary

`+ New` (rail), `New chat` (toolbar), Agent ▸ New session (menu), `/new`, and
`Ctrl-N`. Meanwhile **"Prompts" appears twice** with a name that does not say
what it is (saved prompts? the system prompt? automations?). Redundancy is not
free: it makes the toolbar look like a list of everything rather than a list of
what matters. Recommend: rename Prompts to **Automations** (which is what the
store calls them), and drop the toolbar's duplicate of what the rail already has.

### 2.3 The model is displayed three times at once

Status bar, composer chip, and the rail's footer all show `claude-opus-5`. One
of them should be the truth and the others should go — probably the composer
chip stays, since that is where you change it.

### 2.4 Errors still carry provider JSON

Better than before, but a `request_id` and a raw JSON body still reach the user
on genuine API failures. The taxonomy in `api.lua` is good; the *detail* line
should be behind something (`/doctor`, or a "details" toggle) rather than in the
face of someone who cannot act on it.

### 2.5 Nothing tells you what boggart can do that other agents cannot

Self-written tools, agent-authored panels, the swarm, the capability boundary —
none of it appears anywhere a new user will look. The Library panel is the
showcase and it is three clicks deep with no pointer to it. A single line in the
welcome ("it can write its own tools — see Tools ▸ Library") would earn its
space.

### 2.6 The keyboard-hints line is dense

`enter sends · !cmd runs a shell · shift+enter / ctrl+j newline · tab completes ·
/commands · esc cancels · shift+tab cycles approval · ? shortcuts` — eight
shortcuts in one grey run, at the moment of least context. Two or three matter
on day one; `?` already opens the full overlay.

---

## 3. What is genuinely good — do not churn it

- **`doctor`.** Comprehensive, plain-spoken, exits non-zero. Among the best of
  its kind in any tool of this shape.
- **The welcome screen's copy.** "Pick one. Nothing is sent anywhere until you
  do." — states the privacy question before it is asked.
- **FLEET's empty states.** Every pane says what it would contain and how to
  make that happen.
- **The composer.** Completion, `@` files, `!` shell, mode cycling, history —
  it is at parity with the peers and it feels it.
- **The permission bar.** A visible, cycling mode is the thing people notice in
  Codex, and it is here on both surfaces.

---

## 4. Suggested order

1. **The first-run panel** (§2.1) — the largest single gain available.
2. **De-duplicate the chrome** (§2.2, §2.3) — cheap, and it makes the app look
   decided rather than accumulated.
3. **Demote error detail** (§2.4).
4. **Point at the Library** (§2.5) — one line, disproportionate payoff.

Items 2–4 are each an afternoon. Item 1 is a design pass and should be done
deliberately, with real suggestions, or not at all.
