require_relative "./smoke_test_helper"

Thread.current.name = "FST"

class FinalSmokeTest
	attr_reader :op_log, :m

	def initialize(seed:, interval:, op_count:, logger:, edn_file: File.open("/dev/null"))
		@seed, @interval, @op_count, @logger, @edn_file = seed, interval, op_count, logger, edn_file

		@rng = Random.new(@seed)
		@op_log = []
		@olm = Mutex.new
		@m = Mutex.new
		@ednm = Mutex.new
	end

	def run(nodes)
		threads = []

		@edn_file.write("[")

		@op_count.times do |i|
			start = Time.now

			op = select_op

			o = op.new(nodes: nodes, rng: @rng, logger: @logger, op_id: i, fst: self)

			threads << Thread.new do
				Thread.current.name = "O#{i}"

				o.apply
			end

			sleep [Time.now - start + @interval.rand, 0].max
		end

		threads.each(&:join)

		print "..."

=begin
		until threads.empty?
			threads.select!(&:alive?)

			threads.each do |th|
				th.join(1)
				if th.status
					puts
					puts
					puts "{#{th.name})"
					puts th.backtrace
					th.kill
				end
			end
		end
=end
	ensure
		@edn_file.puts("]")
	end

	def <<(v)
		@olm.synchronize { @op_log << v }
	end

	def edn(e)
		@ednm.synchronize do
			pid = if e[:process] =~ /\AC(\d+)(?:-(\d+))?\z/
				r = $1.to_i
				m = $2.to_i
				m * 5 + r
			else
				raise "FFS"
			end

			@edn_file.puts "{:process #{pid}, :type #{e[:type].inspect}, :f #{e[:f].inspect}, :value #{e[:value].inspect}}"
			@edn_file.fsync
		end
	end


	private

	def select_op
		n = @rng.rand(op_weight_count)

		Op.const_get(Op.constants.sort.find { |c| n -= Op.const_get(c)::WEIGHT; n <= 0 })
	end

	def op_weight_count
		@op_weight_count ||= Op.constants.inject(0) { |a, c| a + Op.const_get(c)::WEIGHT }
	end

	module EvinrudeHooks
		def initialize(*_)
			super
		end
	end

	class Op
		include Evinrude::LoggingHelpers

		def initialize(nodes:, rng:, logger:, op_id:, fst:)
			@nodes, @rng, @logger, @op_id, @fst = nodes, rng, logger, op_id, fst
		end

		private

		def random_node
			@fst.m.synchronize { @nodes.sort[@rng.rand(@nodes.length)] }
		end

		class ExecCommand < Op
			WEIGHT = 20

			def apply
				node = random_node

				node.m.synchronize do
					logger.info(logloc) { "Sending command #{@op_id} to node #{node.t.name}" }
					print ">"

					begin
						return if node.crashed?
						@fst.edn(process: node.t.name, type: :invoke, f: :write, value: @op_id, index: @op_id * 2)
						node.c.command(@op_id.to_s)
						@fst.edn(process: node.t.name, type: :ok, f: :write, value: @op_id, index: @op_id * 2 + 1)
					rescue => ex
						log_exception(ex) { "Sending command #{@op_id} to node #{node.t.name}" }
						@fst.edn(process: node.t.name, type: :info, f: :write, value: @op_id, index: @op_id * 2 + 1)
						node.crashed!
					end

					logger.info(logloc) { "ExecCommand complete" }
				end
#				{ id: @op_id, op: :write, value: @op_id.to_s, node: node.c.node_name, start_time: start.to_f, duration: Time.now - start }
			end
		end

		class ReadState < Op
			WEIGHT = 20

			def apply
				node = random_node

				node.m.synchronize do
					logger.info(logloc) { "Reading state from node #{node.t.name}" }
					print "<"

					begin
						return if node.crashed?
						@fst.edn(process: node.t.name, type: :invoke, f: :read, value: nil, index: @op_id * 2)
						v = node.c.state
						@fst.edn(process: node.t.name, type: :ok, f: :read, value: v == "" ? nil : v.to_i, index: @op_id * 2 + 1)
					rescue => ex
						log_exception(ex) { "Reading state from node #{node.t.name}" }
						@fst.edn(process: node.t.name, type: :fail, f: :read, value: nil, index: @op_id * 2 + 1)
						node.crashed!
					end

					logger.info(logloc) { "ReadState complete" }
				end
#				{ id: @op_id, op: :read, value: v, node: node.c.node_name, start_time: start.to_f, duration: Time.now - start }
			end
		end

		class CrashNode < Op
			WEIGHT = 1

			def apply
				victim = random_node

				@fst.m.synchronize do
					print "!"

					@nodes.delete(victim)

					begin
						victim.m.synchronize do
							node_name, rev = victim.t.name.split("-", 2)
							rev = rev.to_i + 1

							start = Time.now

							@logger.info(logloc) { "Crashing node #{node_name}" }
							victim.crashed!
							victim.t.kill

							@fst.edn(process: victim.t.name, type: :info, f: :crash, index: @op_id * 2)

							if @rng.rand > 0.9
								@logger.info(logloc) { "Removing existing node state" }
								$tmpdir.join(node_name, "snapshot.yaml").unlink rescue nil
								$tmpdir.join(node_name, "log.yaml").unlink rescue nil
							end

							@logger.info(logloc) { "Spawning replacement #{node_name}" }

							until leader = @nodes.find { |n| n.c.leader? }
								@logger.info(logloc) { "Waiting until the cluster has a leader" }
								sleep 0.5
							end

							lazarus = ClusterNode.new(node_name: node_name, shared_keys: ["s3kr1t"], storage_dir: $tmpdir.join(node_name).to_s, logger: default_logger, join_hints: leader.c.nodes)
							lazarus.t.name = "#{node_name}-#{rev}"

							@nodes << lazarus

							until lazarus.c.leader? || lazarus.c.follower?
								@logger.info(logloc) { "Waiting for replacement #{node_name} to join the cluster" }
								sleep 0.5
							end
						rescue => ex
							log_exception(ex) { "Crashing node #{node_name.inspect}" }
						end
					end
				end

#				{ id: @op_id, op: :crash, node: victim.c.node_name, start_time: start.to_f }
			end
		end
	end

	class Checker
		def initialize(log)
			@log = log
		end

		def valid?
			valid_values = []
			final_value = [nil, nil]
			final_at = nil

			@log.sort_by { |e| e[:start_time] }.each do |entry|
				if entry[:op] == :write
				end
			end
		end
	end

	module ClusterNodeAdditions
		attr_reader :m

		def initialize(*_)
			@m = Mutex.new

			super
		end
	end
end

ClusterNode.prepend(FinalSmokeTest::ClusterNodeAdditions)

Evinrude.prepend(FinalSmokeTest::EvinrudeHooks)

seed = (ENV["FST_SEED"] || rand(65536)).to_i
op_count = (ENV["FST_OPS"] || 1000).to_i

puts "Commencing Evinrude Final Smoke Test, seed=#{seed}, op_count=#{op_count}"

st = FinalSmokeTest.new(seed: seed, op_count: op_count, logger: default_logger, interval: 0.05..0.2, edn_file: $tmpdir.join("fst.edn").open("w"))

print "Spawning nodes..."
nodes = spawn_nodes(5, storage_base_dir: $tmpdir.to_s)
puts " done."

print "Waiting for stability..."
wait_for_stability(nodes)
puts " done."

print "Running ops..."
st.run(nodes)

#$tmpdir.join("fst.log").write(st.op_log.to_yaml)

#assert FinalSmokeTest::Checker.new(nodes).valid?, "FST oplog validity"

puts " done!"
