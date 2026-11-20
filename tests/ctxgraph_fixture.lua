-- tests/ctxgraph_fixture.lua -- a scripted 40-step agent transcript for the
-- graph-memory tests: reads, installs (one fails), three versions of one file,
-- a failing test command repeated three times, a passing re-run, a shift to
-- other files, a spawn, and reasoning on some steps.
--   local msgs = dofile("tests/ctxgraph_fixture.lua")()
return function()
  local msgs = { { role = "user", content = "Port the parser in src/parser.py to the new grammar and make the tests pass." } }
  local n = 0
  local function step(call, result, opts)
    opts = opts or {}
    n = n + 1
    local id = "t" .. n
    local content = {}
    if opts.think then content[#content + 1] = { type = "thinking", thinking = opts.think, signature = "sig" } end
    if opts.text then content[#content + 1] = { type = "text", text = opts.text } end
    content[#content + 1] = { type = "tool_use", id = id, name = call[1], input = call[2] }
    msgs[#msgs + 1] = { role = "assistant", content = content }
    msgs[#msgs + 1] = { role = "user", content = { { type = "tool_result", tool_use_id = id, content = result,
      is_error = result:sub(1, 11) == "Tool error:" or nil } } }
  end
  local function read(p, lines) step({ "read", { path = p } }, string.format("%s lines 1-%d of %d\n1\tx", p, lines, lines)) end
  local fail = "[exit=1]\n============ FAILURES ============\n    assert parse('1+2') == 3\nE   AssertionError: expected 3, got None\n1 failed in 0.12s"

  -- 1-4: look around
  read("src/parser.py", 120, nil)
  read("src/lexer.py", 80)
  read("tests/test_parser.py", 40)
  step({ "bash", { command = "ls src tests" } }, "[exit=0]\nsrc:\nparser.py\nlexer.py\ntests:\ntest_parser.py")
  -- 5-6: installs, one fails
  step({ "bash", { command = "pip install numpy==1.26.4" } }, "[exit=0]\nSuccessfully installed numpy-1.26.4",
    { think = "numpy is needed for the grammar tables" })
  step({ "bash", { command = "pip install grammarkit" } },
    "[exit=1]\nERROR: Could not find a version that satisfies the requirement grammarkit\nERROR: No matching distribution found for grammarkit")
  -- 7: first version of the parser
  step({ "write", { path = "src/parser.py", content = "def parse(s):\n    return None\n" } },
    "Wrote src/parser.py (30 bytes, 3 lines)", { text = "Rewrite the parser for the new grammar." })
  -- 8-10: the same failing test, three times
  for _ = 1, 3 do step({ "bash", { command = "python -m pytest tests/test_parser.py" } }, fail) end
  -- 11: second version
  step({ "edit", { path = "src/parser.py", old = "return None", new = "return eval(s)" } },
    "Edited src/parser.py. Post-edit context (lines 1-3 of 3):\n1\tdef parse(s):\n2\t    return eval(s)",
    { think = "eval is enough for the test; replace it later" })
  -- 12: passes
  step({ "bash", { command = "python -m pytest tests/test_parser.py" } }, "[exit=0]\n1 passed in 0.03s")
  -- 13-24: docs, elsewhere entirely
  for i = 1, 6 do
    read("docs/grammar" .. i .. ".md", 10 * i)
    step({ "write", { path = "docs/grammar" .. i .. ".md", content = "# Grammar part " .. i .. "\n" } },
      "Wrote docs/grammar" .. i .. ".md (17 bytes, 2 lines)")
  end
  -- 25: a sub-agent
  step({ "spawn", { task = "Review src/parser.py for unsafe eval" } }, "agent 42 started",
    { text = "Get a second opinion on the eval." })
  -- 26-33: third version and its checks
  step({ "edit", { path = "src/parser.py", old = "return eval(s)", new = "return arith(s)" } },
    "Edited src/parser.py. Post-edit context (lines 1-3 of 3):\n1\tdef parse(s):\n2\t    return arith(s)")
  for _ = 1, 2 do
    step({ "bash", { command = "python -m pytest tests/test_parser.py" } },
      "[exit=1]\nE   NameError: name 'arith' is not defined\n1 failed")
  end
  step({ "write", { path = "src/arith.py", content = "def arith(s):\n    return 3\n" } }, "Wrote src/arith.py (28 bytes, 3 lines)")
  step({ "edit", { path = "src/parser.py", old = "def parse", new = "from arith import arith\ndef parse" } },
    "Edited src/parser.py. Post-edit context (lines 1-4 of 4):\n1\tfrom arith import arith")
  step({ "bash", { command = "python -m pytest tests/test_parser.py" } }, "[exit=0]\n1 passed in 0.02s")
  step({ "bash", { command = "git status --short" } }, "[exit=0]\n M src/parser.py\n?? src/arith.py")
  step({ "bash", { command = "git diff --stat" } }, "[exit=0]\n src/parser.py | 3 ++-")
  -- 34-40: wrap-up across config files
  for i = 1, 7 do read("config/part" .. i .. ".toml", i) end
  return msgs, n
end
