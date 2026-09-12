-- skill: tdd -- red → green test-driven development (model-invoked).
-- Adapted from mattpocock/skills engineering/tdd for boggart's skill template.
return {
  description = "Test-driven development: red→green vertical slices. Use when "
    .. "building features or fixing bugs test-first, or when the user mentions TDD.",
  invocation = "model",
  fallback = "core",
  tools = { "read", "write", "edit", "bash", "list", "choose" },

  -- before: pin the repo root and DETECT the test command that exists here by
  -- stat'ing project files (no command is run -- running the suite is the action
  -- the model takes in STEP 3). Threads the detected command into the turn so the
  -- model does not spend a turn figuring out how this project tests. Guarded so it
  -- degrades to {} without git present.
  before = function()
    local function sh(cmd)
      local ok, out = pcall(function() return bog.C("bash")({ command = cmd }) end)
      if ok and type(out) == "string" then return out end
      return nil
    end
    local function exists(p) return sys.stat and sys.stat(p) == "file" end
    local set = {}
    local root = sh("git rev-parse --show-toplevel 2>/dev/null")
    if root then root = root:gsub("%s+$", "") end
    if root and root ~= "" and not root:find("^Tool error:") then set.root = root end
    -- Detect the test runner from the manifest that is present, most specific first.
    if exists("CMakeLists.txt") or sys.stat and sys.stat("build") == "dir" then
      set.test_cmd = "ctest --test-dir build --output-on-failure (or cmake --build build --target test)"
    elseif exists("package.json") then
      set.test_cmd = "npm test"
    elseif exists("Cargo.toml") then
      set.test_cmd = "cargo test"
    elseif exists("Makefile") or exists("makefile") then
      set.test_cmd = "make test"
    elseif exists("pyproject.toml") or exists("setup.py") or sys.stat and sys.stat("tests") == "dir" then
      set.test_cmd = "pytest"
    end
    return { set = set }
  end,

  -- verify: the "did it go green?" check is a runtime command (the detected test
  -- runner), so it stays a model-run nudge rather than an arg-free code check.
  verify = { tool = "bash", nudge = "re-run the project's test command and confirm "
    .. "the suite is GREEN (it was red before the fix); name that proving command "
    .. "in the report." },

  instructions = function(ctx)
    local root = ctx and ctx.root
    local test_cmd = ctx and ctx.test_cmd
    local head = ""
    if root then head = head .. "Repo root: `" .. root .. "`.\n" end
    if test_cmd then
      head = head .. "Detected test command: `" .. test_cmd .. "` (confirm before relying on it).\n"
    end
    return head .. [[
# Test-Driven Development

Work the red → green loop. Produce tests worth keeping: behaviour through public
interfaces, not implementation details.

If `CONTEXT.md` exists, read it so test names and vocabulary match the domain.

## STEP 1 — Agree seams
A seam is the public boundary you test at. List the seams under test and confirm
them with the user via `choose` (or a short numbered question). No test is written
at an unconfirmed seam.

## STEP 2 — One vertical slice
One seam, one failing test, then only enough code to pass it.
- Red before green. Do not anticipate future tests or speculative features.
- Expected values come from an independent source of truth (literal, worked
  example, or spec) — never tautological recomputation of the code under test.
- Avoid implementation-coupled tests (private methods, internal mocks, DB side
  channels). Avoid horizontal slicing (all tests then all code).

## STEP 3 — Run the suite
Use `bash` for the project's test command. Show the failing run (red), then the
passing run (green). Fix until green.

## STEP 4 — Report
Summarize: seams agreed, tests added/changed (paths), and the command that
proves green. Do not dump large output into chat.

Refactoring is NOT part of this loop — use the `code_review` skill for that.
]]
  end,
}
