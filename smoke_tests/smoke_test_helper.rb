require "evinrude"
require "logger"
require "fileutils"
require "pathname"

$tmpdir = Pathname.new($0).join("..", "..", "tmp", "smoke_test", File.basename($0, ".rb"))

FileUtils.mkdir_p($tmpdir)

def logger; default_logger; end

include Evinrude::LoggingHelpers

class ClusterNode
	include Comparable

	attr_reader :c, :t

	def initialize(*args)
		@c = Evinrude.new(*args)
		@t = Thread.new do
			begin
				@c.run
			rescue Exception => ex
				log_exception(ex) { "Node thread crashed" }
				@crashed = true
				raise
			end
		end
		@t.abort_on_exception = true

		@crashed = false
	end

	def <=>(o)
		@t.name.to_s <=> o.t.name.to_s
	end

	def crashed?
		@crashed
	end

	def crashed!
		@crashed = true
	end
end

def default_logger
	@default_logger ||= begin
		Logger.new($tmpdir.join("log")).tap do |l|
			l.formatter = ->(s, t, p, m) {
				"#{t.strftime("%T.%N")} #{s[0]} #{$$}##{Thread.current.name || "??"} [#{p}] #{m}\n"
			}
			l.level = Logger.const_get(ENV.fetch("SMOKE_TEST_LOG_LEVEL", "DEBUG"))
		end
	end
end

def spawn_nodes(n, args: { shared_keys: ["s3kr1t"], logger: default_logger }, storage_base_dir: nil)
	if storage_base_dir
		args[:storage_dir] = File.join(storage_base_dir, "C1")
	end

	n1 = ClusterNode.new(**args.merge(join_hints: nil, node_name: "C1"))
	n1.t.name = "C1"

	until n1.c.port
		n1.t.join(0.01)
	end

	[n1].tap do |nodes|
		(2..n).each do |i|
			if storage_base_dir
				args[:storage_dir] = File.join(storage_base_dir, "C#{i}")
			end

			nodes << ClusterNode.new(**args.merge(join_hints: [{ address: n1.c.address, port: n1.c.port }], node_name: "C#{i}"))
			nodes.last.t.name = "C#{i}"
		end
	end
end

def wait_for_stability(cluster)
	loop do
		cluster.each do |n|
			until n.c.follower? || n.c.leader?
				n.t.join(0.1)
			end
			n.__send__(:logger).info("wait_for_stability") { "#{n.t.name} is ready" }
		end

		if !cluster.any? { |n| n.c.leader? }
			cluster.first.__send__(:logger).info("wait_for_stability") { "No leader yet" }
			cluster.first.t.join(0.5)
		else
			cluster.first.__send__(:logger).info("wait_for_stability") { "Cluster is stable" }
			return
		end
	end
end

def wait_for_consensus(cluster)
	until leader = cluster.find { |n| n.c.leader? };
		cluster.first.t.join(0.1)
	end

	until cluster.all? { |n| n.c.instance_variable_get(:@commit_index) == leader.c.instance_variable_get(:@log).last_index }
		leader.t.join(0.1)
		leader.__send__(:logger).debug("wait_for_consensus") do
			"#{leader.t.name}.last_index=#{leader.c.instance_variable_get(:@log).last_index} " +
				cluster.map { |n| "#{n.t.name}.commit_index=#{n.c.instance_variable_get(:@commit_index)}" }.join(" ")
		end
	end
end

def assert_equal(a, e, msg = nil)
	loc = caller_locations.first
	logloc = "#{File.basename(loc.path)}:#{loc.lineno}"
	if e == a
		logger.info(logloc) { "PASS: #{a.inspect} == #{e.inspect}" + (msg ? " (#{msg})" : "") }
	else
		logger.error(logloc) { "FAIL: Expected #{e.inspect}, got #{a.inspect}" + (msg ? " (#{msg})" : "") }
		exit 1
	end
end

def assert(v, msg = nil)
	loc = caller_locations.first
	logloc = "#{File.basename(loc.path)}:#{loc.lineno}"
	if v
		logger.info(logloc) { "PASS: #{v.inspect} is true" + (msg ? " (#{msg})" : "") }
	else
		logger.debug(logloc) { "FAIL: #{v.inspect} is falsy" + (msg ? " (#{msg})" : "") }
		exit
	end
end

module FaultInjector
	class Pauser
		def initialize
			@pause = false
			@mutex = Mutex.new
			@cv    = ConditionVariable.new
		end

		def maybe_pause
			@mutex.synchronize { while @pause; @cv.wait(@mutex); end }
		end

		def pause!
			@mutex.synchronize { @pause = true }
		end

		def unpause!
			@mutex.synchronize { @pause = false; @cv.broadcast }
		end
	end

	def self.injected(_)
		raise RuntimeError, "This module should be prepended"
	end

	def self.extended(_)
		raise RuntimeError, "This module should be prepended"
	end

	def pause!(m)
		logger.debug(logloc) { "Pausing #{m}" }
		unless respond_to?(m, true)
			raise ArgumentError, "No method #{m.inspect} to pause"
		end

		unless FaultInjector.method_defined?(m, false)
			logger.debug(logloc) { "Defining pause-enabled version of #{m}" }
			FaultInjector.module_eval do
				define_method(m) do |*a|
					@pausers ||= Hash.new { |h, k| h[k] = Pauser.new }
					logger.debug(logloc) { "PREPAUSE: #{m}" }
					@pausers[m].maybe_pause
					logger.debug(logloc) { "POSTPAUSE: #{m}" }
					super(*a)
				end
			end
		end

		@pausers ||= Hash.new { |h, k| h[k] = Pauser.new }
		@pausers[m].pause!
	end

	def unpause!(m)
		logger.debug(logloc) { "Unpausing #{m}" }
		unless @pausers.key?(m)
			raise ArgumentError, "No paused method #{m.inspect} to unpause"
		end

		@pausers ||= Hash.new { |h, k| h[k] = Pauser.new }
		@pausers[m].unpause!
	end
end
