-- story/sets.lua -- the built-in library of style SETS: generic narration
-- profiles (person, tense, distance) a book can build on. They hold only what
-- is true of the mode itself -- the narration line the drafter is given and
-- the checks that catch a slip out of it -- never a book's voice. A book opts
-- in explicitly (`extends = "first-past"` in one of its sets); nothing here is
-- applied by default.
--
-- Lookup order for a set named N (story/style.lua): the book's own inline
-- `sets`, then <book>/.boggart/style/sets/N.lua, then ~/.boggart/style/sets/N.lua,
-- then this table. A set may itself `extends` another.
local M = {}

local function person(p) return { id = "Set.Person", type = "metric", metric = "person", person = p, level = "warning" } end
local function tense(t) return { id = "Set.Tense", type = "metric", metric = "tense", tense = t, level = "warning" } end

M["first-past"] = {
  narration = "first person, past tense: the narrator tells what happened to them; never report what they could not see or know",
  voice = { "The narrator's own words carry the voice: what they notice, how they judge it, what they won't say." },
  rules = { person("first"), tense("past") },
}
M["first-present"] = {
  narration = "first person, present tense: the narrator lives it as it happens; no hindsight, no foreshadowing from later",
  voice = { "Immediate and unreflective: the narrator doesn't know how this ends." },
  rules = { person("first"), tense("present") },
}
M["third-past"] = {
  narration = "close third person, past tense: stay inside one POV per scene; the narration may use their words but never 'I'",
  voice = { "Close third: the POV's perceptions and vocabulary colour the narration; no head-hopping within a scene." },
  rules = { person("third"), tense("past") },
}
M["third-present"] = {
  narration = "close third person, present tense: one POV per scene, told as it happens",
  voice = { "Close third, present: immediate, one POV per scene." },
  rules = { person("third"), tense("present") },
}
M["third-omniscient"] = {
  narration = "third person omniscient, past tense: the narrator may move between minds, but only at scene or section breaks",
  voice = { "An overseeing narrator with its own voice; knows more than any character and may say so sparingly." },
  rules = { person("third"), tense("past") },
}
M["second-present"] = {
  narration = "second person, present tense: 'you' do and feel; keep it consistent, never slide into 'I' or 'he'",
  voice = { "Second person, present: the reader is addressed as the one acting." },
  rules = { tense("present"), { id = "Set.Person", type = "metric", metric = "person", person = "third", level = "warning" } },
}
-- epistolary / documents: no person or tense rule -- the documents decide
M["documents"] = {
  narration = "documents in the world (letters, reports, transcripts): each in its own form and author's register",
  voice = { "Each document sounds like its author and its kind; no narrator between them." },
  rules = {},
}

return M
