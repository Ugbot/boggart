-- skill: comms -- every agent has this (bus messaging).
return {
  description = "Message other agents and topics over the swarm bus.",
  instructions = "You can `send` a message to another agent by id, `publish` to a topic, "
    .. "`subscribe` to topics, and read your `inbox`. Use these to coordinate with peers.",
  tools = { "send", "publish", "subscribe", "inbox" },
}
