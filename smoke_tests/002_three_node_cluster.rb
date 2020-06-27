#!/usr/bin/env ruby

require_relative "./smoke_test_helper"

require "evinrude"

Thread.current.name = "MT"

nodes = spawn_nodes(3)

n1, n2, n3 = nodes

wait_for_stability(nodes)
wait_for_consensus(nodes)

assert_equal n1.c.nodes.map(&:name).sort, nodes.map(&:c).map(&:node_name).sort
assert_equal n2.c.nodes.map(&:name).sort, nodes.map(&:c).map(&:node_name).sort
assert_equal n3.c.nodes.map(&:name).sort, nodes.map(&:c).map(&:node_name).sort

n1.c.command("bob")

wait_for_consensus(nodes)

assert_equal n1.c.state, "bob"
assert_equal n2.c.state, "bob"
assert_equal n3.c.state, "bob"

n2.c.command("fred")

wait_for_consensus(nodes)

assert_equal n1.c.state, "fred"
assert_equal n2.c.state, "fred"
assert_equal n3.c.state, "fred"

[Thread.new { n1.c.command("c1") }, Thread.new { n2.c.command("c2") }, Thread.new { n3.c.command("c3") }].each(&:join)

wait_for_consensus(nodes)

val = n1.c.state

assert_equal val, n2.c.state
assert_equal val, n3.c.state
