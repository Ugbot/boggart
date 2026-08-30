-- tests/voice.lua -- the native voice module (src/lvoice.c), exercised headless.
--
-- Two layers, so this suite is green in every build:
--   * Shape + degradation: the `voice` global exists and its API is well-formed
--     whether or not BOGGART_VOICE was compiled in. This is all that runs in the
--     default (voice-OFF) build and in CI.
--   * Transcription: only when the binary was built with voice AND the model is
--     present does it actually transcribe the bundled fixture and assert the
--     words came back. Deterministic and offline -- no mic, no network.
--
-- Run: `boggart --eval tests/voice.lua`. cwd is the repo root under --eval, which
-- the fixture path relies on.

local fails = 0
local function check(ok, msg)
  if not ok then fails = fails + 1; io.write("  FAIL: ", msg, "\n") end
end

-- ---- the module is always present ------------------------------------------
check(type(voice) == "table", "voice global is a table")
check(type(voice.built) == "function", "voice.built is a function")
check(type(voice.available) == "function", "voice.available is a function")
check(type(voice.model_path) == "function", "voice.model_path is a function")
check(type(voice.transcribe_wav) == "function", "voice.transcribe_wav is a function")

-- ---- well-formed results, in any build -------------------------------------
local built = voice.built()
check(type(built) == "boolean", "voice.built() returns a boolean")

local avail = voice.available()
check(type(avail) == "boolean", "voice.available() returns a boolean")
-- available implies built: you cannot be usable without the code compiled in.
check(not avail or built, "voice.available() implies voice.built()")

local mp = voice.model_path()
check(mp == nil or type(mp) == "string", "voice.model_path() is a string or nil")
if type(mp) == "string" then
  check(mp:match("%.bin$") ~= nil, "model_path names a .bin file: " .. mp)
end

-- ---- degradation: voice-OFF build reports cleanly, never crashes -----------
if not built then
  check(avail == false, "voice.available() is false when not built")
  local text, err = voice.transcribe_wav("tests/fixtures/voice/quick_brown_fox.wav")
  check(text == nil and type(err) == "string",
    "transcribe_wav returns nil,err when voice is not built")
  io.write("ok  voice: shape + degradation (built without BOGGART_VOICE)\n")
  if fails > 0 then io.write(string.format("FAILED: %d assertion(s)\n", fails)); os.exit(1) end
  return
end

-- ---- transcription (voice-ON build) ----------------------------------------
-- Missing model is a graceful nil,err -- CI may build voice without the weights.
if not avail then
  local text, err = voice.transcribe_wav("tests/fixtures/voice/quick_brown_fox.wav")
  check(text == nil and type(err) == "string",
    "transcribe_wav returns nil,err when the model is absent")
  io.write("ok  voice: built, model absent -- reported cleanly (skipped transcription)\n")
  if fails > 0 then io.write(string.format("FAILED: %d assertion(s)\n", fails)); os.exit(1) end
  return
end

-- Built AND model present: the real smoke test. The fixture says the pangram;
-- whisper should recover its distinctive content words.
local fixture = "tests/fixtures/voice/quick_brown_fox.wav"
local text, err = voice.transcribe_wav(fixture)
check(type(text) == "string", "transcribe_wav returns text: " .. tostring(err))
if type(text) == "string" then
  local low = text:lower()
  check(low:find("quick", 1, true) ~= nil, "transcript contains 'quick': " .. text)
  check(low:find("brown", 1, true) ~= nil, "transcript contains 'brown': " .. text)
  check(low:find("fox", 1, true) ~= nil, "transcript contains 'fox': " .. text)
end

-- A missing file is an error, not a crash.
local t2, e2 = voice.transcribe_wav("tests/fixtures/voice/does-not-exist.wav")
check(t2 == nil and type(e2) == "string", "transcribe_wav of a missing file returns nil,err")

if fails == 0 then
  io.write("ok  voice: transcription -> " .. text .. "\n")
else
  io.write(string.format("FAILED: %d assertion(s)\n", fails))
  os.exit(1)
end
