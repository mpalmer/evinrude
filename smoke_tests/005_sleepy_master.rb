#!/usr/bin/env ruby

require_relative "./smoke_test_helper"

require "evinrude"
require "logger"

Thread.current.name = "MT"

nodes = spawn_nodes(5)

wait_for_stability(nodes)

leader = nodes.find { |n| n.c.leader? }
followers = nodes.select { |n| n.c.follower? }

leader.c.singleton_class.prepend(FaultInjector)
leader.c.pause!(:issue_append_entries)

until new_leader = followers.find { |n| n.c.leader? }
	leader.t.join(1)
end

leader.c.unpause!(:issue_append_entries)

leader.t.join(1)

assert leader.c.follower?
