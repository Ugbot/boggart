-- claims.lua -- the shared edit blackboard (lua/claims.lua): concurrent agents
-- claim files so they coordinate instead of colliding. Logic is driven directly;
-- the tools are exercised through the real registry.
local C = require("claims")
local tools = require("tools")

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

-- ---- write is exclusive across agents --------------------------------------
ok(C.claim("src/a.lua", "write", "A") == true, "A claims a.lua for write")
local got, held = C.claim("src/a.lua", "write", "B")
ok(got == nil and held:find("write by A"), "B refused, told A holds it")
ok(C.claim("src/a.lua", "write", "A") == true, "A re-claims its own file (idempotent)")

-- path normalisation
got = C.claim("./src/a.lua", "write", "B")
ok(got == nil, "normalised path collides (./src/a.lua == src/a.lua)")

-- release frees it
C.release("src/a.lua", "A")
ok(C.claim("src/a.lua", "write", "B") == true, "after release, B can claim")
C.release("src/a.lua", "B")

-- ---- read shared, writer/reader mutually exclusive -------------------------
ok(C.claim("doc.md", "read", "A") == true, "A reads doc.md")
ok(C.claim("doc.md", "read", "B") == true, "B also reads doc.md (shared)")
got, held = C.claim("doc.md", "write", "C")
ok(got == nil and held:find("read by"), "C cannot write while readers hold it")
C.release("doc.md", "A"); C.release("doc.md", "B")
ok(C.claim("doc.md", "write", "A") == true, "A takes write on doc.md")
got, held = C.claim("doc.md", "read", "B")
ok(got == nil and held:find("write by A"), "B cannot read while A writes it")

-- ---- release_all frees a stopped agent -------------------------------------
C.release_all("A"); C.release_all("B")
C.claim("x", "write", "A"); C.claim("y", "read", "A"); C.claim("z", "write", "A")
C.release_all("A")
ok(C.claim("x", "write", "B") == true and C.claim("z", "write", "B") == true,
   "release_all frees everything a stopped agent held")
C.release_all("B")

-- ---- list / holder ---------------------------------------------------------
C.claim("m", "write", "A"); C.claim("m2", "read", "B")
ok(#C.list() == 2, "list shows both claims")
ok(C.holder("m").writer == "A", "holder reports the writer")
C.release_all("A"); C.release_all("B")

-- ---- wiring + tools through the real registry ------------------------------
ok(tools.registry.claim ~= nil, "claim is registered")
ok(tools.registry.release ~= nil, "release is registered")
ok(tools.registry.claims ~= nil, "claims is registered")

-- current agent takes a file, then a foreign agent is refused via the tool
C.claim("shared.txt", "write", "OTHER")
local out = tools.run("claim", { path = "shared.txt" })
ok(out:find("unavailable") and out:find("OTHER"), "claim tool surfaces the holder to the model")
C.release_all("OTHER")
ok(tools.run("claim", { path = "free.txt" }):find("claimed free.txt"), "claim tool takes a free file")
ok(tools.run("claims"):find("free.txt"), "claims tool lists the held file")
ok(tools.run("release", { path = "free.txt" }):find("released"), "release tool frees it")

io.write(string.format("claims: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
