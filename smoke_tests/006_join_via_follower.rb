#!/usr/bin/env ruby

require_relative "./smoke_test_helper"

require "evinrude"

Thread.current.name = "MT"

nodes = spawn_nodes(3)

wait_for_stability(nodes)
wait_for_consensus(nodes)

follower = nodes.find { |n| n.c.follower? }

newbie = ClusterNode.new(join_hints: [{ address: follower.c.address, port: follower.c.port }], shared_keys: ["s3kr1t"], logger: default_logger)
newbie.t.name = "NW"

newbie.t.join(0.1)

until newbie.c.follower?
	newbie.t.join(0.1)
	logger.info(logloc) { "Waiting for newbie to become a follower" }
end

assert newbie.c.follower?, "Newbie has joined the cluster"
