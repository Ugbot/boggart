-- errors.lua -- how boggart behaves when things go wrong outside its control,
-- and where credentials live.
--
-- The motivating complaint: typing "hello" with no API key produced
--
--   · agent 1 crashed: embedded:api:67: no ANTHROPIC_API_KEY set and ...
--
-- which presents a *configuration* problem as an internal fault, complete with
-- a file and line number the user cannot act on. Three classes of failure want
-- opposite treatment, and the tests below pin each one:
--
--   configuration  say what to set; never retry; never print a traceback
--   transient      retry with backoff before the user hears about it at all
--   request        surface the server's own explanation, which is usually exact
local api = bog.api

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end
local function eq(a, b, name)
  if a == b then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, " (", tostring(a), " ~= ", tostring(b), ")\n") end
end

bog.userdir = os.tmpname() .. "_boggart_errors"
sys.mkdir_p(bog.userdir)
if bog.db then bog.db:close() end
bog.db = nil
bog.store.open()

-- ---- status classification -------------------------------------------------
local cases = {
  { 401, api.ERR.auth,        true,  false, "401 is a credential problem, fatal, not retried" },
  { 403, api.ERR.auth,        true,  false, "403 likewise" },
  { 404, api.ERR.model,       true,  false, "404 is a wrong model or base URL" },
  { 400, api.ERR.bad_request, false, false, "400 is our request, not retried" },
  { 429, api.ERR.rate_limit,  false, true,  "429 is retried" },
  { 503, api.ERR.overloaded,  false, true,  "503 is retried" },
  { 529, api.ERR.overloaded,  false, true,  "529 (overloaded) is retried" },
  { 500, api.ERR.server,      false, true,  "500 is retried" },
  { 502, api.ERR.server,      false, true,  "502 is retried" },
}
for _, c in ipairs(cases) do
  local kind, msg, opts = api.classify_status(c[1], '{"error":{"message":"detail here"}}')
  eq(kind, c[2], c[5])
  eq(opts.fatal or false, c[3], "  fatal flag for " .. c[1])
  eq(opts.retryable or false, c[4], "  retryable flag for " .. c[1])
  ok(msg:find(tostring(c[1]), 1, true) ~= nil, "  message names the status " .. c[1])
end

-- the server's own explanation is usually the useful part; keep it
local _, _, o400 = api.classify_status(400, "max_tokens: 999999 exceeds the limit")
ok(tostring(o400.hint):find("max_tokens", 1, true) ~= nil,
   "the server's explanation is preserved in the hint")

-- ---- error objects render as prose, not as a table -------------------------
local okc, err = pcall(api.fail, api.ERR.auth, "No API credentials found.",
                       { fatal = true, hint = "Set one of these:\n  /auth key sk-..." })
eq(okc, false, "fail() raises")
ok(api.is_error(err), "the raised value is a typed boggart error")
eq(err.kind, api.ERR.auth, "kind is inspectable")
eq(err.fatal, true, "fatal is inspectable")
ok(tostring(err):find("No API credentials", 1, true) ~= nil, "tostring gives the message")
ok(tostring(err):find("/auth key", 1, true) ~= nil, "tostring includes the hint")
ok(tostring(err):find("table:", 1, true) == nil, "it never renders as a raw table address")

-- ---- bog.try must not bury a diagnosed condition in a traceback ------------
local tok, terr = bog.try(function()
  api.fail(api.ERR.endpoint, "Cannot reach the endpoint.", { hint = "Start the server." })
end)
eq(tok, false, "bog.try reports the failure")
ok(api.is_error(terr), "the typed error survives bog.try intact")
ok(tostring(terr):find("traceback", 1, true) == nil,
   "no stack traceback is attached to a configuration error")

-- an ordinary bug still gets its traceback -- that is what it is for
local bok, berr = bog.try(function() local t = nil; return t.x end)
eq(bok, false, "bog.try reports a genuine bug")
ok(tostring(berr):find("traceback", 1, true) ~= nil, "a real bug still carries a traceback")

-- ---- retry backoff grows and is bounded ------------------------------------
local d1 = math.min(api.RETRY.max_ms, api.RETRY.base_ms)
local d3 = math.min(api.RETRY.max_ms, api.RETRY.base_ms * 4)
local d9 = math.min(api.RETRY.max_ms, api.RETRY.base_ms * 256)
ok(d3 > d1, "backoff grows")
eq(d9, api.RETRY.max_ms, "backoff is capped")
ok(api.RETRY.attempts >= 2 and api.RETRY.attempts <= 6,
   "a bounded number of attempts -- an agent waiting minutes on a wedged "
   .. "endpoint is worse than being told promptly")

-- ---- credentials live in C, and the key is write-only from Lua -------------
-- The key never enters the Lua state: lhttp.c attaches the header itself when a
-- request sets auth = true. That removes the routine exposure -- a global, a
-- table the `sql` tool can dump, a stray log line -- without pretending to
-- contain an agent that has bash. See src/lauth.c for the honest limits.
auth.clear()
eq(auth.has_key(), false, "no key initially")
eq(auth.masked(), "(unset)", "an absent key reads as unset")
eq(auth.base_url(), nil, "no stored base URL initially")

auth.set("api_key", "sk-ant-secret-value-1234567890")
eq(auth.has_key(), true, "has_key sees the stored key")
local masked, src = auth.masked()
eq(src, "stored", "reports where the credential came from")
ok(masked:find("secret", 1, true) == nil, "the masked form hides the middle")
ok(masked:find("^sk%-ant") ~= nil, "...but keeps enough to identify it")

-- The property that matters: nothing on this module hands back the value.
-- Skip the mutators -- calling clear() with no argument would wipe the very
-- credential the rest of this section is asserting about.
local MUTATOR = { set = true, clear = true }
for k, v in pairs(auth) do
  if type(v) == "function" and not MUTATOR[k] then
    local callok, r = pcall(v)
    ok(not (callok and type(r) == "string" and r:find("secret", 1, true)),
       "auth." .. k .. "() does not return the secret")
  end
end

-- base_url and model are configuration rather than secrets, so they are readable
auth.set("base_url", "http://127.0.0.1:8000")
eq(auth.base_url(), "http://127.0.0.1:8000", "base_url round-trips")
eq(api.endpoint(), "http://127.0.0.1:8000/v1/messages", "stored base_url selects the endpoint")
auth.set("base_url", "http://example/v1/messages")
eq(api.endpoint(), "http://example/v1/messages", "an explicit /v1/messages URL is left alone")
auth.set("model", "deepseek-v4-flash")
eq(auth.model(), "deepseek-v4-flash", "model round-trips")

auth.clear("base_url")
eq(auth.base_url(), nil, "clearing one setting works")
eq(api.endpoint(), "https://api.anthropic.com/v1/messages", "and the default returns")
eq(auth.has_key(), true, "clearing one setting leaves the others alone")
auth.clear()
eq(auth.has_key(), false, "clear() with no argument removes everything")
ok(select(1, auth.set("nonsense", "x")) == nil, "an unknown setting is rejected")

-- ---- a generated tool has no route to a credential -------------------------
-- auth/http are absent from the sandbox environment entirely, and getenv
-- refuses secret-looking names. Not airtight -- a tool can still shell out --
-- but it closes the casual one-liner, which is the realistic leak.
bog.tools.run("define_tool", { name = "peek", description = "d", scope = "session",
  lua = "return tostring(auth) .. '|' .. tostring(http) .. '|' "
     .. ".. tostring(os.getenv('ANTHROPIC_API_KEY')) .. '|' .. tostring(os.getenv('HOME'))" })
local peeked = bog.tools.run("peek", {})
ok(peeked:find("^nil|nil|nil|") ~= nil,
   "auth, http and a secret-looking env var are all unreachable: " .. peeked)
ok(peeked:match("|([^|]+)$") ~= "nil", "an ordinary env var still works")

if bog.db then bog.db:close() end
sys.rmtree(bog.userdir)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
return failed == 0 and 0 or 1
