-- story -- boggart's story module: writing books with lore that stays consistent.
--
-- Pure Lua. It uses only what the core already offers everyone -- SQLite with
-- FTS5 (bog.db), sys.*, git.checkpoint, the model transport (api/route/sched)
-- -- and adds no C. Everything story-specific lives in this directory; the rest
-- of boggart touches it only through this file:
--
--   require("story").register()        the `story` tool, for the model
--   require("story").command(args, w)  /story in the TUI/REPL (the author)
--   require("story").cli(argv)         `boggart story ...` (text, exit code)
--
-- boot.lua calls those three, each under pcall, so a broken or removed module
-- costs the /story command and nothing else. Like every Lua module it can be
-- overlaid: ~/.boggart/lua/story/<file>.lua replaces the built-in one.
--
-- The parts (see docs/story-model.md for the design):
--   story.book    a book's manifest (.boggart/story.json), chapters, variants
--   story.index   rebuildable file index (sty_*): chapters, sheets, payoffs, FTS
--   story.style   one style engine; each book's rules are data in its own repo
--   story.draft   plan (beats -> paragraph lines) and expansion, bounded context
--   story.model   the story model (st_*): entities, events + deltas, state as
--                 of story time, facts, knowledge, promises, proposals, mirror
--   story.world   the tool nouns over the model (author = canon, model = proposal)
--   story.core    the `story` tool itself: nouns, dispatch, schema
--   story.view    what /story prints
--   story.cli     `boggart story ...`
local M = {}

M.PARTS = { "book", "index", "style", "lint", "sets", "slop", "baseline", "decode", "stylecmd", "draft", "model", "world", "core", "view", "cli" }

function M.register() return require("story.core").register() end
function M.command(args, width) return require("story.view").command(args, width) end
function M.cli(argv) return require("story.cli").run(argv) end
function M.call(a) return require("story.core").call(a) end

return M
