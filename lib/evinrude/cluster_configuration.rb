class Evinrude
	class ClusterConfiguration
		class TransitionInProgressError < StandardError; end

		include Evinrude::LoggingHelpers

		def initialize(logger:, metrics:)
			@logger, @metrics = logger, metrics
			@old = []
			@new = []
			@transition_in_progress = false
			@metrics.joint_configuration.set(0)
			@m = Mutex.new
		end

		def transitioning?
			@transition_in_progress
		end

		def nodes
			locked = false
			unless @m.owned?
				@m.lock
				locked = true
			end

			(@old + @new).uniq
		ensure
			@m.unlock if locked
		end

		def add_node(node_info)
			@m.synchronize do
				if @transition_in_progress
					raise TransitionInProgressError,
					      "Cannot add a node whilst a config transition is in progress (@old=#{@old.inspect}, @new=#{@new.inspect})"
				end

				logger.debug(logloc) { "Commencing addition of #{node_info.inspect} to cluster config" }

				# Adding a new node with the same name but, presumably, a different
				# address and/or port triggers a config change in which the old
				# address/port is removed and the new address/port is added.
				existing_node = @old.find { |n| n.name == node_info.name }

				@new = @old + [node_info] - [existing_node].compact
				if @metrics
					@metrics.node_count&.set(nodes.length)
					@metrics.joint_configuration.set(1)
				end
				@transition_in_progress = true
			end
		end

		def remove_node(node_info, force: false)
			@m.synchronize do
				if @transition_in_progress && !force
					raise TransitionInProgressError,
					      "Cannot remove a node whilst a config transition is in progress"
				end

				logger.debug(logloc) { "Commencing #{force ? "forced " : ""}removal of #{node_info.inspect} from cluster config" }

				@new = @old - [node_info]
				if @metrics
					@metrics.node_count&.set(nodes.length)
					@metrics.joint_configuration.set(1)
				end
				@transition_in_progress = true

				if force
					joint_configuration_replicated
				end
			end
		end

		def joint_configuration_replicated
			unlock = false

			unless @m.owned?
				@m.lock
				unlock = true
			end

			logger.debug(logloc) { "Joint configuration has been replicated" }
			@old = @new
			@new = []
			@transition_in_progress = false
			@metrics&.joint_configuration&.set(0)
		ensure
			@m.unlock if unlock
		end

		def quorum_met?(present_nodes)
			@m.synchronize do
				group_quorum?(@old, present_nodes) && group_quorum?(@new, present_nodes)
			end
		end

		def [](id)
			nodes.find { |n| n.id == id }
		end

		def encode_with(coder)
			@m.synchronize do
				instance_variables.each do |iv|
					next if %i{@logger @metrics @m}.include?(iv)
					coder[iv.to_s.sub(/^@/, '')] = instance_variable_get(iv)
				end
			end
		end

		def init_with(coder)
			@m = Mutex.new

			coder.map.each do |k, v|
				instance_variable_set(:"@#{k}", v)
			end
		end

		def inspect
			@m.synchronize do
				"#<#{self.class}:0x#{object_id.to_s(16)} " +
					instance_variables.map do |iv|
						next nil if iv == :@logger || iv == :@metrics
						"#{iv}=#{instance_variable_get(iv).inspect}"
					end.compact.join(" ")
			end
		end

		def logger=(l)
			if @logger
				raise ArgumentError, "Logger cannot be changed once set"
			end

			@logger = l
		end

		def metrics=(m)
			if @metrics
				raise ArgumentError, "Metrics cannot be changed once set"
			end

			@metrics = m
		end

		private

		attr_reader :old, :new

		def group_quorum?(group, present_nodes)
			if group.length < 2
				# Quorum is automatically met if the group isn't in use (empty) or
				# if the group is just one (which can only be "us")
				true
			else
				logger.debug(logloc) { "Checking if #{present_nodes.inspect} meets quorum requirement for #{group.inspect}" }
				(group.select { |m| present_nodes.include?(m) }.length.to_f / group.length.to_f > 0.5).tap { |v| logger.debug(logloc) { v ? "Quorum met" : "Quorum failed" } }
			end
		end
	end
end
