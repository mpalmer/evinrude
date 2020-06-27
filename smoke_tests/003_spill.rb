#!/usr/bin/env ruby

require_relative "./smoke_test_helper"

require "evinrude"

Thread.current.name = "MT"

nodes = spawn_nodes(5)

wait_for_stability(nodes)
wait_for_consensus(nodes)

prev_leader = nodes.find { |n| n.c.leader? }
prev_leader.t.kill
nodes.delete(prev_leader)
default_logger.info(logloc) { "Whacked leader #{prev_leader.t.name} to force election" }

wait_for_stability(nodes)

nodes.find { |n| n.c.follower? }.c.command("bob")

nodes.each do |n|
	assert_equal n.c.state, "bob", n.t.name
end
