# Contributing to boggart

## Licence, in one paragraph

boggart is **source-available, not open source**: [Business Source License
1.1](./LICENSE). Read it, use it, change it, run it — including commercially and
inside your company. The one thing you may not do is offer it to third parties
as a competing hosted or embedded product. Each version converts to
**GPL-3.0-or-later** on **2030-09-04**, or four years after that version was
first published, whichever comes first. That conversion is automatic and
irrevocable: nothing here can be taken back later.

## Sign your commits (DCO)

Contributions are accepted under the [Developer Certificate of
Origin](./DCO) — the same mechanism the Linux kernel uses. It is not a copyright
assignment and it does not give anyone the right to relicense your work; it is
you certifying that you wrote the contribution, or have the right to submit it.

Add a sign-off line to each commit:

```
git commit -s -m "your message"
```

which appends:

```
Signed-off-by: Your Name <your.email@example.com>
```

Use your real name and an address you read. If you forgot on the last commit,
`git commit --amend -s` fixes it.

**What signing off means for you:** your contribution is licensed under the
BSL 1.1 terms above, and converts to GPL-3.0-or-later on the same schedule as
the rest of that version. You keep your copyright.

## Before you open a pull request

Everything here is enforced by a gate, so run them rather than guessing:

```sh
cmake -B build -G Ninja && cmake --build build
ctest --test-dir build           # every Lua suite
ninja -C build core-parity       # the CLI and the studio are one engine
```

If you touched the studio, also:

```sh
ninja -C build ui-check          # renders scenarios and asserts what a frame shows
ninja -C build ui-discover       # every feature reachable from a menu
ninja -C build ui-overlay        # overlays survive partial-damage frames
ninja -C build ui-bench          # drawing stays bounded by the viewport
```

`ui-check`, `ui-discover`, `ui-overlay` and `ui-bench` need a window server, so
they are ninja targets rather than ctest suites.

## What the codebase expects of a change

- **A test that fails before your fix and passes after.** Several of the gates
  above exist because a bug shipped that every existing test was blind to; the
  fix is to add the test that would have caught it, not only the fix.
- **Say why in the comment, not what.** The code says what it does. A comment
  earns its place by recording the thing that is not visible: the failure that
  motivated it, the alternative that was rejected, the constraint that makes the
  obvious approach wrong.
- **Know which side of the C/Lua line you are on.** C is for what Lua cannot
  express, what must not be rewritable, or what is structurally hot —
  [`docs/control-surfaces.md`](./docs/control-surfaces.md) states the rule and
  the ledger. If a change adds C and is none of those three, it probably belongs
  in Lua.
- **Files stay under ~500 lines** where practically possible.
