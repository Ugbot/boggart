-- skill: comms -- every agent has this (bus messaging).
return {
  description = "Message other agents and topics over the swarm bus.",
  -- No before/verify: the only read here (`inbox`) DRAINS the mailbox, so running
  -- it in before would consume messages before the model saw them -- not a safe
  -- idempotent read. Pure capability guidance otherwise.
  instructions = function()
    return "You can `send` a message to another agent by id, `publish` to a topic, "
      .. "`subscribe` to topics, and read your `inbox`. Use these to coordinate with peers."
  end,
  tools = { "send", "publish", "subscribe", "inbox" },
}
