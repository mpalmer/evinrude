#!/usr/bin/env ruby

require_relative "./smoke_test_helper"

require "evinrude"

Thread.current.name = "MT"

nodes = spawn_nodes(5)

wait_for_stability(nodes)
wait_for_consensus(nodes)

nodes.first.c.command("famous five")

nodes.each { |n| assert_equal n.c.state, "famous five", n.t.name }

# For maximum confusion, we make sure that we crash the master
victim = nodes.find { |n| n.c.leader? }
default_logger.info(logloc) { "Crashing node #{victim.t.name}" }
victim.t.kill
nodes.delete(victim)

crashed_nodes_info = []

# And take out another two nodes, to make sure we've lost consensus, but we'll
# keep a note of their identity for later consumption
2.times do
	victim = nodes.last

	crashed_nodes_info << victim.c.node_info
	default_logger.info(logloc) { "Crashing node #{victim.t.name}" }
	victim.t.kill

	nodes.delete(victim)
end

crashed_nodes_info.each do |ni|
	nodes.first.c.remove_node(ni, unsafe: true)
end

# This should work... eventually

nodes.last.c.command("survival of the fittest")

nodes.each { |n| assert_equal n.c.state, "survival of the fittest", n.t.name }
