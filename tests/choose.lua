-- choose.lua -- prose detection and choice UX (lua/choose.lua): detect enumerated
-- questions, build records, parse REPL input, and capture after a turn.
local choose = require("choose")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

-- ---- detect: lettered lists ------------------------------------------------
local d = choose.detect([[
Which approach should we take?

a) Use SQLite for storage
b) Use the filesystem
c) Something else entirely
]])
ok(d and d.prompt:find("Which approach"), "detect: lettered list finds prompt")
ok(d and #d.options == 3 and d.options[1].label:find("SQLite"), "detect: lettered options")

-- ---- detect: numbered lists ------------------------------------------------
d = choose.detect("Pick one:\n\n1. Fix the bug first\n2. Add tests first\n3. Refactor")
ok(d and #d.options == 3 and d.options[2].label:find("tests"), "detect: numbered list")

-- ---- detect: bullets -------------------------------------------------------
d = choose.detect("Would you prefer:\n- Fast iteration\n- Maximum safety")
ok(d and #d.options == 2, "detect: bullet list")

-- ---- detect: rejects -------------------------------------------------------
ok(choose.detect("Just a single bullet:\n- only one") == nil, "detect: one item rejected")
ok(choose.detect("No options here, just a question?") == nil, "detect: bare question rejected")
ok(choose.detect([[
```lua
a) not a real option
b) inside a fence
```
]]) == nil, "detect: options inside code fence ignored")

-- ---- build + render --------------------------------------------------------
local rec, err = choose.build({ prompt = "Pick:", options = { { label = "yes" }, { label = "no" } } })
ok(rec and not err, "build: valid record")
ok(rec.options[1].key == "a" and rec.options[2].key == "b", "build: assigns letter keys")
ok(choose.render(rec):find("a%) yes"), "render: shows lettered menu")

-- ---- parse_line ------------------------------------------------------------
ok(choose.parse_line(rec, "a").index == 1, "parse_line: letter picks option")
ok(choose.parse_line(rec, "maybe").text == "maybe", "parse_line: free text")
ok(choose.parse_line(rec, "").cancel == true, "parse_line: empty cancels")

-- ---- format_user_reply -----------------------------------------------------
ok(choose.format_user_reply(rec, { index = 2 }) == "no", "format_user_reply: index")
ok(choose.format_user_reply(rec, { text = "custom" }) == "custom", "format_user_reply: text")
ok(choose.format_user_reply(rec, { cancel = true }) == nil, "format_user_reply: cancel")

-- ---- session capture -------------------------------------------------------
local sess = { messages = {
  { role = "user", content = "help" },
  { role = "assistant", content = "Which?\n\na) one\nb) two" },
}}
ok(choose.capture_from_session(sess) ~= nil, "capture_from_session: finds trailing list")
local sess2 = { messages = {
  { role = "assistant", content = {
    { type = "text", text = "Which?\n\na) one\nb) two" },
    { type = "tool_use", name = "choose", id = "1", input = {} },
  }},
}}
ok(choose.capture_from_session(sess2) == nil, "capture_from_session: skips after choose tool")

-- ---- sync capture (REPL path) ----------------------------------------------
bog.choose_ask = function(r)
  return choose.parse_line(r, "b")
end
local reply = choose.capture_after_turn({ messages = {
  { role = "assistant", content = "Pick:\n\na) alpha\nb) beta" },
}})
ok(reply == "beta", "capture_after_turn: sync REPL returns chosen label")

io.write(string.format("choose: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
