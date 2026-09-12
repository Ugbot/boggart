-- verify_cmd.lua -- run the project's own checks and decide pass/fail as CODE,
-- so an action skill gates completion without a model turn spent on "did it
-- pass?" (docs/skill-conversion.md, the completion-gate pattern ported from
-- ai-grind verification-before-completion). Shared by verify_complete,
-- finish_branch, simplify, tdd, cmake_* -- one code path for "is it green".
local M = {}

-- Detect the test command this project actually has, by the files present.
-- Returns a command string or nil. Order: most specific first.
function M.detect_test()
  local function has(p) return sys.stat and sys.stat(p) ~= nil end
  if has("CMakeLists.txt") and has("build") then
    return "ctest --test-dir build --output-on-failure"
  end
  if has("Cargo.toml") then return "cargo test" end
  if has("go.mod") then return "go test ./..." end
  if has("package.json") then return "npm test --silent" end
  if has("pyproject.toml") or has("setup.py") or has("pytest.ini") or has("tests") then
    return "pytest -q"
  end
  if has("Makefile") then return "make test" end
  return nil
end

-- Detect the build command, same idea. Returns a string or nil.
function M.detect_build()
  local function has(p) return sys.stat and sys.stat(p) ~= nil end
  if has("CMakeLists.txt") and has("build") then return "cmake --build build" end
  if has("Cargo.toml") then return "cargo build" end
  if has("go.mod") then return "go build ./..." end
  if has("Makefile") then return "make" end
  return nil
end

-- Run `cmd` through the bash tool and read its `[exit=N]` prefix (lua/tools.lua
-- tool_bash). Returns ok(boolean), full_output(string). Missing bash -> false.
function M.run(cmd)
  if not (bog and bog.C) then return false, "no bash tool available" end
  local out = bog.C("bash")({ command = cmd })
  if type(out) ~= "string" then return false, tostring(out) end
  if out:find("^Tool error:") then return false, out end
  local code = out:match("^%[exit=(%-?%d+)")
  return code == "0", out
end

-- The gate: detect the test command, run it, return true when green or the
-- failure output when red. Drops straight into a skill `verify`. When no test
-- command is detectable, returns true (nothing to gate) rather than blocking.
function M.green(cmd)
  cmd = cmd or M.detect_test()
  if not cmd then return true end
  local ok, out = M.run(cmd)
  if ok then return true end
  return "verification failed (`" .. cmd .. "`):\n" .. out
end

return M
