# The built-in tracker

boggart ships its own project tracker, modelled on ai-grind's devtools-mcp
tracker and LLM Station's native tracker (whose design,
`llm-station/docs/architecture/design-native-tracker.md`, is the spec all
three follow). It is one tool for the model, one command for people, one
subcommand for scripts and CI.

| Where | How |
|---|---|
| model | the `tracker` tool (`noun` + `action`, flat parameters) |
| TUI / REPL | `/tracker` |
| studio | Project → Tracker (list or board, with a ticket card) |
| shell / CI | `boggart tracker …` |

Code: `lua/tracker_core.lua` (store, rules, tool), `lua/tracker_view.lua`
(what tickets look like — shared by TUI and studio), `lua/tracker_import.lua`
(ai-grind import), `lua/tracker_file.lua` (the committed file + JUnit),
`lua/tracker_cli.lua`, `studio/data/core/trackerview.lua`. Tests:
`tests/tracker.lua`.

## Model

Projects own `KEY-123` keys, allocated atomically. Tasks form a hierarchy up to
six levels (`epic → story → task → subtask`, plus `spike`, `test`), with
priority 1–5 and a status: `open`, `in_progress`, `blocked`, `in_review`,
`done`, `cancelled`.

- **Acceptance criteria** can link a test (`test_ref`). Closing to `done`
  checks them: a *strict* project refuses while any is unmet or unlinked
  (`override=true` closes anyway); an *advisory* one closes and warns.
- **Dependencies** are cycle-checked and stay inside a project. The resolver
  sorts open tickets into ready / blocked (and on what) / waiting on subtasks,
  and orders them into layers that can run in parallel
  (`deps resolve`, `format=json` for machines).
- **Tags**, with auto-tag rules (by kind, parent kind or a regex over title and
  description) applied at creation.
- **Commits** linked by hand or by scanning `git log` for keys.
- **GitHub issues** created, linked, synced and closed through the `gh` CLI.

## The tool

```
noun      actions
project   create | list | get | set_policy
task      create | get | update | move | breakdown
status    (key, status[, override])
criteria  add | update | record | remove | list
tag       add | remove | rule_add | rule_list | rule_remove
commits   link | scan            (scan: close_keywords=true)
deps      add | remove | list | resolve
issue     create | link | sync | close
query     view=tasks|tree|rollup|criteria|commits|tags|deps|issues
import    one-shot import from ai-grind (path=, project=)
```

The names and parameters are LLM Station's `tracker` tool's, so a skill or a
model uses one vocabulary whichever store answers. Errors are returned as
`Error: …` strings, never raised.

## Backends

```
/tracker backend native     boggart.db (trk_* tables) — the default
/tracker backend station    LLM Station's tracker, over the ZMQ link
```

With `station`, a call is passed through unchanged. If the link is down the
call is an **error**, never a quiet write to the native store: they are
separate stores, and a ticket filed in the wrong one is lost to whoever looks
in the right one. `backend=` on a single call overrides the setting.

## Reading tickets

Readability over decoration. Status is a glyph *and* a place or a word, never
colour alone: `○` open, `◐` in progress, `⊘` blocked, `◑` in review, `✓` done,
`×` cancelled. Keys lead every row; long titles wrap under themselves; no line
is ever wider than the terminal (a test checks 40, 60 and 100 columns).

```
/tracker                 projects, with open/done counts
/tracker BRAIN           what's next: in progress, in review, ready,
                         blocked (and what each waits on), waiting on subtasks
/tracker BRAIN done      finished, most recent first
/tracker BRAIN tree      the hierarchy
/tracker BRAIN-35 [full] one ticket: header, description (trimmed unless
                         `full`), acceptance, waits on, blocks, tags,
                         commits, subtasks
```

The studio's tracker tab draws the same models: the "what's next" list or a
board (a column per status; blocked cards still say what they wait on), with
the selected ticket's card beside either. `j`/`k` or the wheel move, `b`
toggles the board, `p` picks a project, `r` refreshes; everything is clickable,
including the keys under *Waits on* and *Blocks*. `ninja ui-tracker` renders it
to screenshots.

## Importing from ai-grind

```
/tracker import [~/.devtools-mcp/tracker.db]
```

One transaction, read-only on the source. Keys, uids and each project's next
key are kept, so `PROJ-123` means the same ticket in both. A project that
already exists is **skipped, not merged**: the stores are independent
afterwards.

## GitHub

Through the `gh` CLI, which already handles login (keychain locally,
`GH_TOKEN` in CI), Enterprise hosts and token scopes. boggart stores only the
link.

```
tracker issue create key=BOG-7 [repo=owner/name]   title "[BOG-7] …", body =
                                                   description + criteria
                                                   checklist + back-reference;
                                                   labels from tags that exist
tracker issue link   key=BOG-7 number=12           an issue (or PR) you already have
tracker issue sync   key=BOG-7 | project=BOG       refresh, and report drift:
                                                   closed on GitHub but open
                                                   here, or the other way round
tracker issue close  key=BOG-7 [message=…]         close with a comment
```

`repo` defaults to the checkout's (`gh repo view`). A merged pull request
counts as closed.

## CI: the tracker in the repository

A CI runner has no `~/.boggart`, so the tracker for a repository lives in it,
as `.boggart/tracker.jsonl`:

- one JSON object per line, keys sorted, records in a fixed order;
- references by key and uid — never database ids;
- no volatile fields (last-run and last-synced times), so re-running a job
  with the same results changes nothing, and a real change is a one-line diff.

`import-file` replaces exactly the projects the file contains, in one
transaction; `export-file` writes atomically. `export → import → export` is
byte-identical (tested).

```
boggart tracker export-file [path] [project=K,…]   default .boggart/tracker.jsonl
boggart tracker import-file [path]
boggart tracker record-junit results.xml [project=K,…]
boggart tracker commits scan repo=. close_keywords=true
boggart tracker <noun> <action> key=value …        any tool call
boggart tracker BRAIN | BRAIN-35                   the same text /tracker prints
```

Exit status is 1 whenever the answer is an error, so a step fails when the
tracker says no. No first-run banner is printed for this subcommand.

`record-junit` fills acceptance results from JUnit XML — what most test
runners emit, including `ctest --output-junit`. A criterion's `test_ref`
matches a testcase by `name`, `classname::name` or `path::name`; any failing
match fails it; skipped cases are ignored.

`close_keywords=true` makes `commits scan` treat GitHub's closing keywords
(`fix`/`fixes`/`fixed`, `close…`, `resolve…`, then a key) as a move to `done`
— still through the close gate, so a strict project with failing criteria
stays open and the scan says why.

### A GitHub Actions workflow

Not installed by default (a file under `.github/workflows/` runs on the next
push); copy it in when you want it:

```yaml
# .github/workflows/tracker.yml
name: tracker
on:
  push:
    branches: [main]
permissions:
  contents: write        # push the updated tracker file
  issues: write          # issue sync/close
jobs:
  tracker:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 200 }
      - name: Build
        run: cmake -S . -B build -G Ninja && cmake --build build --target boggart
      - name: Test
        run: cd build && ctest --output-junit ../junit.xml || true
      - name: Update the tracker
        env: { GH_TOKEN: "${{ github.token }}" }
        run: |
          ./boggart tracker import-file
          ./boggart tracker record-junit junit.xml
          ./boggart tracker commits scan repo=. close_keywords=true
          ./boggart tracker issue sync project=BOG || true
          ./boggart tracker export-file
      - name: Commit the tracker if it changed
        run: |
          git diff --quiet .boggart/tracker.jsonl && exit 0
          git config user.name  "boggart-tracker"
          git config user.email "tracker@users.noreply.github.com"
          git commit -am "tracker: sync from ${GITHUB_SHA::7}" && git push
```

## Not done yet

- Replication between boggart, ai-grind and LLM Station after the one-shot
  import (each is its own store; the committed file is how a repository shares
  one).
- The file-claim collaboration layer from ai-grind.
- The studio tab always shows the native store; with the station backend it
  says so rather than drawing station's.
