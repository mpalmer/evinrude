#!/usr/bin/env ruby

require_relative "./smoke_test_helper"

require "evinrude"

Thread.current.name = "MT"

n = spawn_nodes(1).first

c = n.c
t = n.t

until c.leader?
	t.join(0.001)
end

c.command("bob")

assert_equal c.state, "bob"
