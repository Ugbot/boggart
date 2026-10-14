-- Exercise the same process-backed terminal binding in Studio's engine.
-- SDL dummy driver validates the shared binding; it is not a renderer test.
local ok, err=pcall(dofile,'tests/terminal_process.lua')
if not ok then io.stderr:write(tostring(err),'\n'); os.exit(1) end
os.exit(0)
