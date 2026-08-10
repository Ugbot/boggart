-- gold.lua -- "golden" starting-point toolkit: a small, blessed standard
-- library baked into boggart that the agent (and the tools it writes) can rely
-- on instead of reinventing basics. Exposed as the global `gold`. It is part of
-- the pristine starting setup materialized by `boggart init`; the agent is free
-- to overlay and evolve any of it under ~/.boggart/lua/gold/.
return {
  str = require("gold.str"),   -- string helpers
  tbl = require("gold.tbl"),   -- table/list helpers
  fs = require("gold.fs"),     -- filesystem helpers
  pp = require("gold.pp"),     -- pretty-print / inspect
  args = require("gold.args"), -- shell-ish tokenizing + flag parsing
  test = require("gold.test"), -- tiny assert harness for self-testing tools
  sh = require("gold.sh"),     -- convenience wrappers over sys.exec
  json = require("json"),      -- JSON encode/decode
}
