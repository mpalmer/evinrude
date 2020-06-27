#!/usr/bin/env ruby

require_relative "./smoke_test_helper"

require "evinrude"

Thread.current.name = "MT"

nodes = spawn_nodes(5)

wait_for_stability(nodes)
wait_for_consensus(nodes)

nodes.first.c.command("famous five")

nodes.each { |n| assert_equal n.c.state, "famous five", n.t.name }

2.times do
	victim = nodes.last

	info = Evinrude::NodeInfo.new(address: victim.c.address, port: victim.c.port, name: victim.c.node_name)

	default_logger.info(logloc) { "Removing node #{victim.t.name}" }
	victim.c.remove_node(info)
	victim.t.kill

	nodes.delete(victim)
end

# We should still have a working cluster at the moment, regardless
nodes.first.c.command("now we are three")

nodes.each { |n| assert_equal n.c.state, "now we are three", n.t.name }

victim = nodes.first
default_logger.info(logloc) { "Crashing node #{victim.t.name}" }
victim.t.kill
nodes.delete(victim)

# If the earlier removals went OK, we should *still* have a working cluster
nodes.first.c.command("two is tops")

nodes.each { |n| assert_equal n.c.state, "two is tops", n.t.name }
