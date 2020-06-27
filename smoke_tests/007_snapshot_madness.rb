#!/usr/bin/env ruby

require_relative "./smoke_test_helper"

require "evinrude"

Thread.current.name = "MT"

nodes = spawn_nodes(3, storage_base_dir: $tmpdir.to_s)

wait_for_stability(nodes)
wait_for_consensus(nodes)

nodes.each.with_index { |n, i| n.c.command(n.t.name) }

wait_for_consensus(nodes)

first_state = nodes.first.c.state

nodes.each do |n|
	assert_equal YAML.load_stream($tmpdir.join(n.t.name, "log.yaml").read).last[:commit_entries_to], [n.c.instance_variable_get(:@commit_index)], "#{n.t.name} logged commit_entries_to"
end

nodes.each { |n| n.c.__send__(:take_snapshot) }

nodes.each do |n|
	snap = YAML.load_file($tmpdir.join(n.t.name, "snapshot.yaml"))

	assert_equal snap.state, first_state, "#{n.t.name} state"
end

nodes.each.with_index { |n, i| n.c.command(n.t.name) }

wait_for_consensus(nodes)

mid_state = nodes.first.c.state

victim = nodes.find { |n| n.t.name == mid_state }
nodes.delete(victim)

victim.t.kill

assert_equal YAML.load_stream($tmpdir.join(victim.t.name, "log.yaml").read).last[:commit_entries_to], [nodes.first.c.instance_variable_get(:@commit_index)], "Victim #{victim.t.name} had up-to-date commit_index"

nodes.each.with_index { |n, i| n.c.command(n.t.name) }

wait_for_consensus(nodes)

new_state = nodes.first.c.state

assert new_state != mid_state, "Check that we've got a new state"

lazarus = ClusterNode.new(shared_keys: ["s3kr1t"], logger: default_logger, storage_dir: $tmpdir.join(victim.t.name).to_s)
lazarus.t.name = "LZ"

nodes << lazarus

wait_for_consensus(nodes)

assert_equal lazarus.c.state, new_state, "Ensure lazarus has synced up"

# Phatten the log file
log_file = $tmpdir.join("C1", "log.yaml")
until log_file.size > 500_000
	lazarus.c.command("logloglog!" * 1000)
end

# Now keep phattening the log file until it gets tiny again -- indicating
# a snapshot was taken -- or it gets stupidly huge
until log_file.size < 500_000 || log_file.size > 2_000_000
	lazarus.c.command("xyzzy!" * rand(1000))
end

assert log_file.size < 32_000_000, "Log file didn't get truncated; was a snapshot even taken?"

# Can a new node, starting completely from scratch, load from a master's snapshot?
newbie = ClusterNode.new(shared_keys: ["s3kr1t"], logger: default_logger, storage_dir: $tmpdir.join("newbie").to_s, node_name: "NB", join_hints: [{ address: lazarus.c.address, port: lazarus.c.port }])
newbie.t.name = "NB"

nodes << newbie

wait_for_consensus(nodes)

assert_equal newbie.c.state, lazarus.c.state, "Ensure newbie is synced"

# As a final test, let's make sure the in-memory log trimming is working OK
nodes.each { |n| n.t.kill }

log = nodes.first.c.instance_variable_get(:@log)

2000.times do |i|
	log.append(Evinrude::LogEntry::Null.new(term: i + 1))
end

assert log.instance_variable_get(:@entries).length < 1001, "Log entries length kept under control"
assert_equal log.last_entry_term, 2000, "All log entries are recorded"
assert_equal log.instance_variable_get(:@snapshot_last_term), log.instance_variable_get(:@entries).first.term - 1, "The snapshot->live log entries transition is correct"
