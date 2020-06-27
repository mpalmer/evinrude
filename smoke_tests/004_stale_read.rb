#!/usr/bin/env ruby

require_relative "./smoke_test_helper"

require "evinrude"

Thread.current.name = "MT"

nodes = spawn_nodes(5)

wait_for_stability(nodes)
wait_for_consensus(nodes)

leader = nodes.find { |n| n.c.leader? }

leader.c.command("bob")

wait_for_consensus(nodes)

chosen_one = nodes.find { |n| n.c.follower? }

assert_equal "bob", chosen_one.c.state

victims = nodes.select { |n| n != leader && n != chosen_one }

victims.each do |v|
	v.c.singleton_class.prepend(FaultInjector)
	v.c.pause!(:process_append_entries_request)
end

# Pop this in a separate thread because, if all goes well, this will block
cmd_t = Thread.new { Thread.current.name = "CT"; chosen_one.c.command("fred") }
cmd_t.abort_on_exception = true

# 640 milliseconds ought to be enough for anyone!
cmd_t.join(0.64)

assert_equal cmd_t.status, "sleep", "Command thread initial wait"

# This should also block
st_t = Thread.new { Thread.current.name = "ST"; chosen_one.c.state }
st_t.abort_on_exception = true

st_t.join(0.64)

assert_equal cmd_t.status, "sleep", "Command thread re-check"
assert_equal st_t.status, "sleep", "State retrieval thread"

# The fact that both of those threads are still waiting patiently indicates
# that the leader is being queried, and yet it hasn't achieved consensus
# (because a majority of the cluster is unresponsive).  Now let's open up
# the floodgates and see what comes out!

victims.each { |v| v.c.unpause!(:process_append_entries_request) }

cmd_t.join(10)

assert_equal cmd_t.status, false, "Command thread completed"

nodes.each do |n|
	assert_equal "fred", n.c.state, n.t.name
end

st_t.join(10)

assert_equal st_t.status, false, "State thread completed"
assert_equal st_t.value, "fred", "State thread gives new value"
