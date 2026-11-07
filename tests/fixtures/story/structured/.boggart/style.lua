return {
  limits = { max_words = 30, avg_max = 20, the_way_budget = 1, same_opener_run = 3 },
  banned = { "software", "okay", "—" },
  tells = { "in other words" },
  chains = true,
  refrains = { list = { "not today" }, max = 1 },
  pov = { vera = "Clipped. Counts things." },
  bits = { voice = "Sentences stay under {{max_words}} words.", pov = "One POV per chapter." },
  order = { "voice", "pov" },
}
