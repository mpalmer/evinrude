require "async"
require "async/dns"
require "fiber"
require "logger"
require "pathname"
require "securerandom"
require "tempfile"

require_relative "./evinrude/logging_helpers"

class Evinrude
	include Evinrude::LoggingHelpers

	class Error < StandardError; end

	class NoLeaderError < Error; end

	class NodeExpiredError < Error; end

	attr_reader :node_name

	def initialize(join_hints: [], shared_keys:, state_machine: Evinrude::StateMachine::Register,
	               logger: Logger.new("/dev/null"), node_name: nil, storage_dir: nil,
	               heartbeat_interval: 0.25, heartbeat_timeout: 1..2,
	               listen: {}, advertise: {}, metrics_registry: Prometheus::Client::Registry.new)
		@join_hints, @keys, @logger, @heartbeat_interval, @heartbeat_timeout = join_hints, shared_keys, logger, heartbeat_interval, heartbeat_timeout

		@metrics = Evinrude::Metrics.new(metrics_registry)

		@listen, @advertise = listen, advertise
		@listen[:address] ||= "::"
		@listen[:port]    ||= 0

		if storage_dir
			@storage_dir = Pathname.new(storage_dir)
		end

		snapshot = if @storage_dir
			if !@storage_dir.exist?
				@storage_dir.mkdir
			end

			if !@storage_dir.directory?
				raise ArgumentError, "Storage directory #{@storage_dir} isn't *actually* a directory"
			end

			snapshot_file = @storage_dir.join("snapshot.yaml")

			if snapshot_file.exist?
				@metrics.snapshot_file_size.set(snapshot_file.stat.size)
				YAML.load_file(snapshot_file)
			end
		end

		@state_machine_class = state_machine

		if snapshot
			@node_name        = snapshot.node_name
			@state_machine    = @state_machine_class.new(snapshot: snapshot.state)
			@last_command_ids = snapshot.last_command_ids
		else
			@node_name        = node_name || SecureRandom.uuid
			@state_machine    = @state_machine_class.new
			@last_command_ids = {}
		end

		@sm_mutex      = Mutex.new

		if snapshot
			@config        = snapshot.cluster_config
			@config_index  = snapshot.cluster_config_index
			@config.metrics = @metrics
			@config.logger  = logger
		else
			@config       = Evinrude::ClusterConfiguration.new(logger: logger, metrics: @metrics)
			@config_index = 0
		end

		@last_append  = Time.at(0)
		@current_term = 0
		@voted_for    = nil
		@mode         = :init

		@metrics.term.set(0)

		if snapshot
			logger.debug(logloc) { "Configuring log from snapshot; snapshot_last_term=#{snapshot.last_term} snapshot_last_index=#{snapshot.last_index}" }
			@log = Evinrude::Log.new(snapshot_last_term: snapshot.last_term, snapshot_last_index: snapshot.last_index, logger: logger)
		else
			@log = Evinrude::Log.new(logger: logger)
		end

		if snapshot
			logger.debug(logloc) { "Setting commit_index to #{snapshot.last_index} from snapshot" }
			@commit_index = snapshot.last_index
		else
			@commit_index = 0
		end

		@metrics.commit_index.set(@commit_index)

		@peers = Hash.new do |h, k|
			backoff = Evinrude::Backoff.new

			peer_conn = @network.connect(address: k.address, port: k.port)

			h[k] = Peer.new(metrics: @metrics, conn: peer_conn, node_info: k, next_index: @log.last_index + 1)
		end

		@config_change_queue = []
		@config_change_request_in_progress = nil
		@cc_sem = Async::Semaphore.new
	end

	def command(s)
		@metrics.command_execution.measure do
			Async(logger: logger) do |task|
				command_id = SecureRandom.uuid

				loop do
					reply = rpc_to_leader(Message::CommandRequest.new(command: s, id: command_id, node_name: @node_name), task)

					if reply.success
						break true
					end
				end
			end.result
		end
	end

	def state
		@metrics.read_state.measure do
			Async(logger: logger) do |task|
				loop do
					state_object = nil
					commit_index = nil

					@sm_mutex.synchronize do
						# Disturbingly, this appears to be one of the best available ways
						# to make a guaranteed deep copy of an arbitrary object
						state_object = YAML.load(@state_machine.current_state.to_yaml)
						commit_index = @commit_index
					end

					logger.debug(logloc) { "(in #{@node_name}) Checking if #{state_object.inspect} at commit_index=#{commit_index} is the most up-to-date state" }

					reply = rpc_to_leader(Evinrude::Message::ReadRequest.new(commit_index: commit_index), task)

					if reply.success
						break state_object
					end
				end
			end.result
		end
	end

	def run
		logger.info(logloc) { "Evinrude node #{@node_name} starting up" }

		@metrics.start_time.set(Time.now.to_f)

		if @storage_dir
			@metrics.log_loaded_from_disk.set(1)
			load_log_from_disk
		else
			@metrics.log_loaded_from_disk.set(0)
		end

		Async do |task|  #(logger: logger) do |task|
			@async_task = task
			@network = Network.new(keys: @keys, logger: logger, metrics: @metrics, listen: @listen, advertise: @advertise).start

			logger.info(logloc) { "Node #{@node_name} listening on #{address}:#{port}" }

			@metrics.info.set(1, labels: { node_name: @node_name, listen_address: @network.listen_address, listen_port: @network.listen_port, advertise_address: address, advertise_port: port })

			task.async { process_rpc_requests }

			join_or_create_cluster
		end.return
	rescue => ex
		log_exception(ex) { "Fatal error" }
		raise
	end

	def remove_node(node_info, unsafe: false)
		if unsafe
			logger.warn(logloc) { "Unsafely removing node #{node_info.inspect} from the local configuration" }

			@config.remove_node(node_info, force: true)
		else
			@metrics.remove_node.measure do
				Async(logger: logger) do |task|
					loop do
						logger.debug(logloc) { "(in #{@node_name}) Requesting removal of #{node_info.inspect}" }

						reply = rpc_to_leader(Evinrude::Message::NodeRemovalRequest.new(node_info: node_info, unsafe: unsafe), task)

						if reply.success
							break true
						end
					end
				end.result
			end
		end
	end

	def address
		@network&.advertised_address
	end

	def port
		@network&.advertised_port
	end

	def nodes
		@config.nodes
	end

	def leader?
		@mode == :leader
	end

	def follower?
		@mode == :follower
	end

	def candidate?
		@mode == :candidate
	end

	def init?
		@mode == :init
	end

	def expired?
		!!(!leader? && @heartbeat_timeout_time && @heartbeat_timeout_time < Time.now)
	end

	def node_info
		if @network.nil?
			raise RuntimeError, "Cannot determine node info until the network is up"
		end

		@node_info ||= Evinrude::NodeInfo.new(address: address, port: port, name: @node_name)
	end

	private

	def load_log_from_disk
		log_file = @storage_dir.join("log.yaml")

		if log_file.exist?
			logger.debug(logloc) { "Loading log entries from #{log_file}" }
			@metrics.log_file_size.set(log_file.stat.size)

			# Temporarily unsetting @storage_dir prevents the calls we make from
			# writing all the log entries straight back to disk again
			tmp_storage_dir, @storage_dir = @storage_dir, nil

			begin
				log_file.open do |fd|
					YAML.load_stream(fd) do |entry|
						unless entry.is_a?(Hash)
							logger.fatal(logloc) { "SHENANIGAN ALERT: persisted log entry #{entry} is not a hash!" }
							exit 42
						end

						m, args = entry.to_a.first

						unless %i{process_log_entry commit_entries_to}.include?(m)
							logger.fatal(logloc) { "SHENANIGAN ALERT: log includes unexpected operation #{m.inspect}(*#{args.inspect})!!!" }
							exit 42
						end

						logger.debug(logloc) { "Running #{m}(#{args.inspect}) from disk log" }

						self.__send__(m, *args)
					end
				end
			ensure
				@storage_dir = tmp_storage_dir
			end

			logger.debug(logloc) { "Completed log read" }
		end
	end

	def rpc_to_leader(msg, task)
		backoff    = Evinrude::Backoff.new
		reply      = nil
		command_id = SecureRandom.uuid

		logger.debug(logloc) { "(in #{@node_name}) Sending message #{msg.inspect} to cluster leader" }

		loop do
			until leader? || follower? || expired?
				logger.debug(logloc) { "(in #{@node_name}) Waiting until we're in the cluster before sending RPC to leader" }
				task.sleep 0.5
			end

			begin
				remote = reply&.leader_info || @leader_info

				if remote.nil?
					raise NoLeaderError, "No leader could be discerned for the cluster at present"
				end

				conn = @network.connect(address: remote.address, port: remote.port)

				reply = task.with_timeout(5) do |t|
					conn.rpc(msg)
				end

				if reply.nil?
					logger.debug(logloc) { "(in #{@node_name}) RPC to leader #{remote.inspect} timed out" }
				elsif reply.leader_info
					logger.debug(logloc) { "(in #{@node_name}) Redirected to #{reply.leader_info.inspect}" }
					# No need to wait for the backoff time here
					next
				else
					logger.debug(logloc) { "(in #{@node_name}) RPC to leader returned #{reply.inspect}" }
					return reply
				end

				task.sleep backoff.wait_time
			rescue Evinrude::Error, Async::TimeoutError, Async::Wrapper::Cancelled, SystemCallError, IOError => ex
				@metrics.rpc_exception.increment(labels: { target: "#{remote.address}:#{remote.port}", node_name: remote.name, class: ex.class.to_s })
				log_exception(ex) { "(in #{@node_name}) RPC to leader raised exception" }
				conn&.close
				reply = nil

				if expired?
					raise NodeExpiredError, "This node instance is not active in the cluster (mode=#{@mode})"
				end

				task.sleep backoff.wait_time
			end
		end
	end

	def become_leader
		reset_peers

		logger.info(logloc) { "Assuming leadership of the cluster" }

		@mode = :leader

		@leader_info = node_info
		@commands_in_progress = {}

		@cc_sem.acquire do
			@config_change_queue = []
			@config_change_request_in_progress = nil
		end

		@async_task.async do |subtask|
			while leader?
				subtask.sleep @heartbeat_interval

				if leader?
					logger.debug(logloc) { "Triggering periodic AE heartbeat" }
					issue_append_entries_to_cluster
				end
			end
		end

		propose_log_entry(
			LogEntry::Null.new(term: @current_term) do
				logger.debug(logloc) { "Null log entry to mark start-of-term replicated" }
			end
		)

		@metrics.state.set(3)
	end

	def become_follower
		reset_peers

		logger.info(logloc) { "Becoming follower" }

		@mode = :follower

		@heartbeat_timeout_time = Time.now + @heartbeat_timeout.rand

		@async_task.async do |subtask|
			while follower?
				logger.debug(logloc) { "#{@heartbeat_timeout_time - Time.now}s until heartbeat timer expires" }

				subtask.sleep [0.01, @heartbeat_timeout_time - Time.now].max

				if follower? && @heartbeat_timeout_time < Time.now
					logger.info(logloc) { "Heartbeat timeout expired; triggering election" }
					trigger_election
				end
			end
		end

		@metrics.state.set(2)
	end

	def become_candidate
		reset_peers

		logger.info(logloc) { "Becoming a candidate" }

		@mode = :candidate

		@async_task.async do |subtask|
			election_timeout = @heartbeat_timeout.rand
			logger.debug(logloc) { "Waiting #{election_timeout}s for election to complete" }
			subtask.sleep election_timeout

			if candidate?
				logger.info(logloc) { "Election timeout expired without a leader being elected; triggering a new election" }
				trigger_election
			end
		end

		@metrics.state.set(1)
	end

	def reset_peers
		@peers.values.each { |f| f.conn.close }
		@peers.clear
		@metrics.clear_peer_metrics
	end

	def new_term(n)
		logger.debug(logloc) { "Setting up for term #{n}" }
		@current_term = n
		@voted_for = nil

		@metrics.term.set(@current_term)
	end

	def persist_to_disk(e)
		if @storage_dir
			file = @storage_dir.join("log.yaml")

			if file.exist? && file.stat.size > 1024 * 1024
				logger.debug(logloc) { "Log is getting a bit big; time for a new snapshot, methinks" }
				take_snapshot
			end

			logger.debug(logloc) { "Persisting #{e.inspect} to #{file}" }
			file.open("a") do |fd|
				logger.debug(logloc) { "Doin' the write thing" }
				fd.puts e.to_yaml
				fd.fdatasync
			end

			@metrics.log_entries_persisted.increment
			@metrics.log_file_size.set(file.stat.size)
		end
	end

	def propose_log_entry(entry)
		unless leader?
			logger.error(logloc) { with_backtrace("propose_log_entry called while not leader!") }
			return
		end

		@log.append(entry)
		persist_to_disk(process_log_entry: [entry, @log.last_index])

		logger.debug(logloc) { "Proposing #{entry.inspect} as ##{@log.last_index}" }

		if @config.nodes.length == 1
			# Flyin' solo!  Means we can skip all that inconvenient AppendEntries stuff,
			# but we still need to do what needs to be done after the entry has been
			# "replicated everywhere" (ie "here")
			check_for_new_replication_majority
		else
			issue_append_entries_to_cluster
		end
	end

	def issue_append_entries_to_cluster(&blk)
		nodes.each do |n|
			next if n == node_info

			@async_task.async do
				begin
					issue_append_entries(@peers[n], &blk)
				rescue Evinrude::Log::SnapshottedEntryError
					issue_snapshot(@peers[n])
				rescue => ex
					log_exception(ex) { "Failed to issue AppendEntries to #{n.inspect}" }
				end
			end
		end
	end

	def issue_append_entries(follower)
		logger.debug(logloc) { "Issuing AppendEntries to #{follower.node_info.inspect}" }
		entries    = @log.entries_from(follower.next_index)
		prev_index = [follower.next_index - 1, @log.last_index].min
		prev_entry = @log[prev_index]

		logger.debug(logloc) { "Previous log entry (##{prev_index}) is #{prev_entry.inspect}" }

		reply = follower.rpc(
			Message::AppendEntriesRequest.new(
				term:           @current_term,
				leader_info:    node_info,
				leader_commit:  @commit_index,
				prev_log_index: prev_index,
				prev_log_term:  prev_entry.term,
				entries:        entries,
			)
		)

		if leader?
			if reply.nil?
				logger.debug(logloc) { "AppendEntriesRequest to #{follower.node_info.inspect} was not answered.  C'est la vie." }
				follower.conn.close
				@peers.delete(follower.node_info)
			elsif block_given?
				yield reply, follower.node_info
			elsif reply.term > @current_term
				logger.debug(logloc) { "Received term from #{follower.node_info.inspect} greater than our own.  Demotion required!" }
				new_term(reply.term)
				become_follower
			elsif reply.success
				logger.debug(logloc) { "Successful AppendEntriesReply received from #{follower.node_info.inspect}" }
				follower.successful_append(prev_index + entries.length)
				check_for_new_replication_majority
			else
				logger.debug(logloc) { "AppendEntries to #{follower.node_info.inspect} failed; retrying after next_index decrement" }
				if reply.last_index && reply.last_index < follower.next_index - 1
					follower.failed_append(reply.last_index)
				else
					follower.failed_append
				end
				if follower.next_index <= @log.snapshot_last_index
					issue_snapshot(follower)
				else
					issue_append_entries(follower)
				end
			end
		else
			logger.debug(logloc) { "Ignoring AppendEntriesReply received when we're not leader" }
		end
	end

	def check_for_new_replication_majority
		new_commits = false

		((@commit_index + 1)..@log.last_index).each do |idx|
			present_nodes = @peers.values.select { |f| f.match_index >= idx }.map(&:node_info) + [node_info]

			logger.debug(logloc) { "Checking for replication majority on ##{idx} (present: #{present_nodes.inspect})" }
			if @config.quorum_met?(present_nodes)
				logger.debug(logloc) { "Log index #{idx} has met majority" }
				@metrics.replication_majority.set(idx)

				entry = @log[idx]

				case entry
				when LogEntry::ClusterConfiguration
					logger.debug(logloc) { "Newly majoritied (majoritised?) log entry is a ClusterConfig; @config_index=#{@config_index}" }

					# Dealing with potentially out-of-date cluster configurations is
					# absofuckinglutely mind-bending.  As near as I can tell, however,
					# since the leader by definition has all of the log entries, it
					# also has the latest and greatest config live and in concert,
					# so we can make some assumptions about future log entries on
					# that basis.
					if idx == @config_index
						logger.debug(logloc) { "Replication of current config #{@config.inspect} complete" }
						if @config.transitioning?
							logger.debug(logloc) { "Proposing post-joint config" }
							@config.joint_configuration_replicated
							propose_log_entry(LogEntry::ClusterConfiguration.new(term: @current_term, config: @config))
							@config_index = @log.last_index
						else
							# Transition complete; time to let the requestor know they're good
							# to go
							logger.debug(logloc) { "Post-joint config replicated; config change saga completed" }
							@config_index = @log.last_index

							@cc_sem.acquire do
								if @config_change_request_in_progress
									logger.debug(logloc) { "Letting #{@config_change_request_in_progress.node_info.inspect} know their config change request was successful" }

									# This is technically only necessary for certain config changes
									# (like when a node changes address/port but keeps the same
									# name) but there's no harm in doing it all the time.
									if @peers.key?(@config_change_request_in_progress.node_info)
										@peers[@config_change_request_in_progress.node_info].conn.close
										@peers.delete(@config_change_request_in_progress.node_info)
									end

									@config_change_request_in_progress.send_successful_reply
									@config_change_request_in_progress = nil
								else
									logger.debug(logloc) { "Nobody to send a successful config change reply to; oh well" }
								end
							end

							process_config_change_queue
						end
					else
						logger.debug(logloc) { "Quorum met on out-of-date config #{entry.config.inspect}; ignoring" }
					end
				when LogEntry::StateMachineCommand
					@sm_mutex.synchronize do
						logger.debug(logloc) { "Applying state machine command #{entry.command} (id #{entry.id})" }
						@state_machine.process_command(entry.command)
						if conn = @commands_in_progress.delete(entry.id)
							logger.debug(logloc) { "Letting the client know their command is cooked" }
							conn.send_reply(Message::CommandReply.new(success: true))
						else
							logger.debug(logloc) { "No client around to notify of command application; they'll figure it out eventually" }
						end
					end
				end

				@commit_index = idx
				@metrics.commit_index.set(@commit_index)
				persist_to_disk(commit_entries_to: [idx])
				new_commits = true
			else
				logger.debug(logloc) { "Replication majority not yet met on ##{idx}.  Better luck next time." }
			end
		end

		if new_commits
			# We want to get the good word out to everyone as soon as possible that
			# there's new log entries that can be committed.
			issue_append_entries_to_cluster
		end
	end

	def take_snapshot
		return unless @storage_dir

		snapshot = @sm_mutex.synchronize do
			Evinrude::Snapshot.new(node_name: @node_name, state: @state_machine.snapshot, cluster_config: @config, cluster_config_index: @config_index, last_term: @log.last_entry_term, last_index: @log.last_index, last_command_ids: @last_command_ids)
		end

		Tempfile.open("snapshot", @storage_dir) do |f|
			logger.debug(logloc) { "Writing snapshot data to #{f.path}" }
			f.write(snapshot.to_yaml)
			f.fdatasync
			f.close
			File.rename(f.path, @storage_dir.join("snapshot.yaml"))
			File.open(@storage_dir) { |d| d.fsync }
		end

		@metrics.snapshot_file_size.set(@storage_dir.join("snapshot.yaml").stat.size)

		begin
			logger.debug(logloc) { "Deleting now-stale log.yaml" }
			File.unlink(File.join(@storage_dir, "log.yaml"))
		rescue Errno::ENOENT
			# Yes, this is in fact exactly what we're trying to achieve
		end

		@metrics.log_file_size.set(0)
	end

	def issue_snapshot(follower)
		msg = @sm_mutex.synchronize do
			Message::InstallSnapshotRequest.new(term: @current_term, leader_info: @leader_info, last_included_index: @commit_index, last_included_term: @log[@commit_index].term, data: @state_machine.snapshot)
		end

		reply = follower.rpc(msg)

		if reply.term > @current_term
			new_term(reply.term)
		else
			follower.successful_append(@commit_index)
		end
	end

	def async_resolver
		@async_resolver ||= Evinrude::Resolver.new
	end

	def expand_join_hints
		return [] if @join_hints.nil?

		# Where's Enumerable.amap when you need it?
		sem = Async::Semaphore.new

		[].tap do |r|
			@join_hints.each do |jh|
				Async(logger: logger) do |t|
					if jh.is_a?(String)
						async_resolver.getresources(jh).each do |srv|
							t.async do
								async_resolver.getaddresses(srv.target.to_s).each do |addr|
									sem.acquire { r << { address: addr, port: srv.port } }
								end
							end
						end
					elsif jh.is_a?(Hash) || jh.is_a?(NodeInfo)
						begin
							IPAddr.new(jh[:address])
							# It's an IP address already; excellent
							sem.acquire { r << jh }
						rescue ArgumentError
							# It's a hostname(ish)
							async_resolver.getaddresses(jh[:address]).each do |addr|
								sem.acquire { r << { address: addr, port: srv.port } }
							end
						end
					else
						raise ArgumentError, "Invalid join hint entry: #{jh.inspect}"
					end
				end.result
			end
		end
	end

	def join_targets
		expand_join_hints + @config.nodes.reject { |n| n.name == node_info.name }
	end

	def join_or_create_cluster
		if @join_hints.nil? && join_targets.empty?
			logger.info(logloc) { "No hints of an existing cluster found; configuring for standalone mode" }
			new_term(1)

			@config.add_node(node_info)
			@config.joint_configuration_replicated

			become_leader

			propose_log_entry(LogEntry::ClusterConfiguration.new(term: @current_term, config: @config))

			take_snapshot
		else
			logger.info(logloc) { "Joining existing cluster" }
			join_cluster_via(join_targets)

			# Taking a snapshot immediately after joining allows us to capture an
			# up-to-date config, as well as our node name, in case of accidents.
			take_snapshot
		end
	end

	def join_cluster_via(targets)
		connected = false

		logger.debug(logloc) { "Attempting to join cluster via targets #{targets.inspect}" }

		# I call this algorithm "happy joinballs".
		#
		# I will not be taking questions at this time.
		conn_tasks = targets.map do |t|
			@async_task.async do |subtask|
				logger.debug(logloc) { "Initiating happy joinballs connection to #{t[:address]}:#{t[:port]}" }

				begin
					conn = @network.connect(address: t[:address], port: t[:port])
				rescue StandardError => ex
					logger.warn(logloc) { "Failed to connect to #{t[:address]}:#{t[:port]}: #{ex.class} (#{ex.message})" }
					if targets.length == 1
						logger.warn(logloc) { "Cluster leader not responsive; restarting join attempt" }
						join_or_create_cluster
					end

					next
				end

				# If we get here, we have won the happy joinballs race
				conn_tasks.each do |ct|
					next if ct == Async::Task.current

					ct.stop
				end

				logger.debug(logloc) { "Sending a join request to #{conn.peer_info}" }
				reply = subtask.with_timeout(5) do |t|
					conn.rpc(Message::JoinRequest.new(node_info: node_info))
				rescue Async::TimeoutError
					nil
				end

				if reply&.success
					logger.info(logloc) { "Joined cluster; #{reply.inspect}" }
					become_follower
				elsif reply&.leader_info
					logger.debug(logloc) { "Redirected to leader #{reply.leader_info.inspect}" }
					join_cluster_via([reply.leader_info])
				else
					logger.error(logloc) { "Cluster join via #{t.inspect} failed: #{reply.nil? ? "RPC timeout" : reply.inspect}" }
					# Obviously that target is busticated, so we'll retry without it.
					# The problem is that the busticated target might have been a
					# leader we were erroneously redirected to; in that case, the
					# targets list will have only one node, and we'll need to go
					# back to joinballing everyone.  Hopefully by now the cluster
					# will have agreed on a *live* leader for us to join via.
					if targets.length == 1
						join_cluster_via(join_targets - [t])
					else
						join_cluster_via(targets - [t])
					end
				end
			end
		end

		conn_tasks.each(&:wait)
	end

	def process_rpc_requests
		logger.debug(logloc) { "Commencing to process RPC requests" }
		@network.each_message do |msg, conn|
			@metrics.messages_received.increment(labels: { type: msg.class.to_s.split("::").last })

			logger.debug(logloc) { "Received #{msg} from #{conn.peer_info}" }
			reply = case msg
				when Message::AppendEntriesRequest
					process_append_entries_request(msg, conn)
				when Message::CommandRequest
					process_command_request(msg, conn)
				when Message::JoinRequest
					process_join_request(msg, conn)
				when Message::NodeRemovalRequest
					process_node_removal_request(msg, conn)
				when Message::ReadRequest
					process_read_request(msg, conn)
				when Message::VoteRequest
					process_vote_request(msg, conn)
				when Message::InstallSnapshotRequest
					process_install_snapshot_request(msg, conn)
				else
					logger.warn(logloc) { "Unexpected #{msg.class.to_s.split("::").last} received from #{conn.peer_info}" }
					nil
				end

			if reply
				logger.debug(logloc) { "Sending reply #{reply.inspect} to #{conn.peer_info}" }
				conn.send_reply(reply)
			else
				logger.warn(logloc) { "No immediate reply to #{msg.inspect} from #{conn.peer_info}" }
			end
		end
	end

	def process_join_request(msg, conn)
		logger.debug(logloc) { "Join request #{msg.inspect} received from #{conn.peer_info}" }

		if follower?
			logger.debug(logloc) { "Not leader; redirecting" }
			Message::JoinReply.new(success: false, leader_info: @leader_info)
		elsif leader?
			logger.debug(logloc) { "Queueing join request" }
			@config_change_queue << ConfigChangeQueueEntry::AddNode.new(msg, conn)

			if @config_change_queue.length == 1 && @config_change_request_in_progress.nil?
				logger.debug(logloc) { "Triggering new config change queue cascade" }
				process_config_change_queue
			end

			# No immediate reply; will be sent once the join is completed
			nil
		else
			logger.debug(logloc) { "Ignoring join request from #{msg.node_info} because not leader or follower" }
			nil
		end
	end

	def process_node_removal_request(msg, conn)
		logger.debug(logloc) { "Node removal request #{msg.inspect} received from #{conn.peer_info}" }

		if follower?
			logger.debug(logloc) { "Not leader; redirecting" }
			Message::NodeRemovalReply.new(success: false, leader_info: @leader_info)
		elsif leader?
			logger.debug(logloc) { "Queueing node removal request" }
			@config_change_queue << ConfigChangeQueueEntry::RemoveNode.new(msg, conn)

			if @config_change_queue.length == 1
				logger.debug(logloc) { "Triggering new config change queue cascade" }
				process_config_change_queue
			end

			# No immediate reply; will be sent once the join is completed
			nil
		else
			logger.debug(logloc) { "Ignoring node removal request from #{msg.node_info} because not leader or follower" }
			nil
		end
	end

	def process_config_change_queue
		if @config_change_queue.empty?
			logger.debug(logloc) { "No more entries in the config change queue" }
			return
		end

		if @config_change_request_in_progress
			logger.error(logloc) { "Change queue processing requested while change request in progress!" }
			return
		end

		@config_change_request_in_progress = @config_change_queue.shift
		logger.debug(logloc) { "Processing config change queue entry #{@config_change_request_in_progress.inspect}" }

		unless leader?
			@cc_sem.acquire do
				@config_change_request_in_progress.send_redirect_reply(@leader_info)
				@config_change_request_in_progress = nil
			end
			process_config_change_queue
			return
		end

		case @config_change_request_in_progress
		when ConfigChangeQueueEntry::AddNode
			if	@config.nodes.include?(@config_change_request_in_progress.node_info)
				# "Dude, you're *already* part of the cluster!  Duuuuuuuuuuuuuuude!"
				@cc_sem.acquire do
					@config_change_request_in_progress.send_successful_reply
					@config_change_request_in_progress = nil
				end
				process_config_change_queue
			else
				logger.debug(logloc) { "Transitioning configuration to add #{@config_change_request_in_progress.node_info.inspect}" }

				@config.add_node(@config_change_request_in_progress.node_info)
				propose_log_entry(LogEntry::ClusterConfiguration.new(term: @current_term, config: @config))
				@config_index = @log.last_index
			end
		when ConfigChangeQueueEntry::RemoveNode
			if !@config.nodes.include?(@config_change_request_in_progress.node_info)
				@cc_sem.acquire do
					@config_change_request_in_progress.send_successful_reply
					@config_change_request_in_progress = nil
				end
				process_config_change_queue
			else
				logger.debug(logloc) { "Transitioning configuration to remove #{@config_change_request_in_progress.node_info.inspect}" }

				@config.remove_node(@config_change_request_in_progress.node_info)
				propose_log_entry(LogEntry::ClusterConfiguration.new(term: @current_term, config: @config))
				@config_index = @log.last_index
			end
		else
			logger.error(logloc) { "Unsupported change request type #{@config_change_request_in_progress.class}; this really shouldn't ever happen, bug report welcome" }
			logger.debug(logloc) { "Unsupported change request was #{@config_change_request_in_progress.inspect}" }
			@config_change_request_in_progress = nil
			process_config_change_queue
		end
	end

	def process_append_entries_request(msg, conn)
		logger.debug(logloc) { "Processing append_entries request #{msg.inspect} from #{conn.peer_info}" }

		if msg.term < @current_term
			logger.debug(logloc) { "AppendEntries request term less than our current term #{@current_term}" }
			Message::AppendEntriesReply.new(success: false, term: @current_term)
		else
			@last_append = Time.now

			if !@log.has_entry?(msg.prev_log_index)
				logger.debug(logloc) { "We don't have log entry prev_log_index=#{msg.prev_log_index}; asking for more entries" }
				Message::AppendEntriesReply.new(success: false, term: @current_term, last_index: @log.last_index)
			elsif @log.snapshotted_entry?(msg.prev_log_index + 1)
				logger.error(logloc) { "Got AppendEntriesRequest with a prev_log_index=#{msg.prev_log_index} that's buried in the snapshot" }
				# Closing the connection to the leader will cause it to recycle the
				# follower state, which will reset it to start sending us AppendEntries
				# from the most recent entry.
				conn.close
			elsif msg.prev_log_term != @log.entry_term(msg.prev_log_index)
				logger.debug(logloc) { "AppendEntries log fork; msg.prev_log_index=#{msg.prev_log_index} msg.prev_log_term=#{msg.prev_log_term} @log.entry_term(msg.prev_log_index=#{@log.entry_term(msg.prev_log_index)} @log.last_index=#{@log.last_index}" }
				@log.truncate_to(msg.prev_log_index - 1)
				Message::AppendEntriesReply.new(success: false, term: @current_term)
			else
				@leader_info = msg.leader_info

				if msg.term > @current_term || (candidate? && msg.term == @current_term)
					logger.debug(logloc) { "Received term-updating AppendEntries; msg.term=#{msg.term} @current_term=#{@current_term} node_info.mode=#{node_info.instance_variable_get(:@mode).inspect}" }
					new_term(msg.term)
					become_follower
				end

				@heartbeat_timeout_time = Time.now + @heartbeat_timeout.rand

				msg.entries.each.with_index do |new_entry, i|
					idx = msg.prev_log_index + i + 1   # Dratted 1-index addressing
					process_log_entry(new_entry, idx)
				end

				new_commit_point = [@log.last_index, msg.leader_commit].min

				if new_commit_point > @commit_index
					commit_entries_to(new_commit_point)
				end

				Message::AppendEntriesReply.new(success: true, term: @current_term)
			end
		end
	end

	def process_log_entry(entry, log_index)
		logger.debug(logloc) { "Processing #{entry.inspect} at log index #{log_index}" }

		existing_entry = @log[log_index]

		if existing_entry.nil?
			@log.append(entry)

			persist_to_disk(process_log_entry: [entry, log_index])

			# Configuration changes take place immediately, not after consensus;
			# raft.pdf p11, "a server always uses the latest configuration in its
			# log, regardless of whether the entry is committed".
			if LogEntry::ClusterConfiguration === entry
				logger.debug(logloc) { "Using new configuration from log entry ##{log_index}" }
				@config       = entry.config
				@config_index = log_index
			end
		elsif existing_entry.term != entry.term
			logger.debug(logloc) { "Discovered fork at #{log_index} (existing_entry=#{existing_entry.inspect} new_entry=#{entry.inspect}); discarding our remaining log entries" }
			@log.truncate_to(log_index - 1)
		else
			logger.debug(logloc) { "Already got log entry ##{log_index}; skipping" }
		end

	end

	def commit_entries_to(idx)
		((@commit_index + 1)..idx).each do |i|
			@sm_mutex.synchronize do
				logger.debug(logloc) { "Committing log entry ##{i}" }

				if LogEntry::StateMachineCommand === @log[i]
					logger.debug(logloc) { "Applying state machine command #{@log[i].command}" }
					@state_machine.process_command(@log[i].command)
					@last_command_ids[@log[i].node_name] = @log[i].id
				else
					logger.debug(logloc) { "Entry ##{i} is a #{@log[i].class}; no commit action necessary" }
				end

				@commit_index = i
				@metrics.commit_index.set(i)
			end
		end

		persist_to_disk(commit_entries_to: [idx])
	end

	def process_command_request(msg, conn)
		logger.debug(logloc) { "Command request #{msg.inspect} received from #{conn.peer_info}" }

		if follower?
			Message::CommandReply.new(success: false, leader_info: @leader_info)
		elsif leader?
			if @last_command_ids[msg.node_name] == msg.id
				Message::CommandReply.new(success: true)
			else
				logger.debug(logloc) { "Noting that #{msg.id} is a command in progress" }
				@commands_in_progress[msg.id] = conn
				propose_log_entry(LogEntry::StateMachineCommand.new(term: @current_term, command: msg.command, id: msg.id, node_name: msg.node_name))

				# Deferred reply to log entry commit will occur after replication is complete
				nil
			end
		else
			Message::CommandReply.new(success: false)
		end
	end

	def process_vote_request(msg, conn)
		if Time.now - @last_append < @heartbeat_timeout.first
			# Avoid rogue servers disrupting the cluster by calling votes
			# just because they can.
			logger.debug(logloc) { "Ignoring vote request from scurvy rogue #{msg.candidate_info}" }
			return nil
		end

		if msg.term > @current_term
			new_term(msg.term)
		end

		if msg.term == @current_term &&
				(@voted_for.nil? || @voted_for == msg.candidate_info) &&
				((msg.last_log_index >= @log.last_index && msg.last_log_term == @log.last_entry_term) || msg.last_log_term > @log.last_entry_term)
			@voted_for = msg.candidate_info
			become_follower
			logger.debug(logloc) { "Voted for #{msg.candidate_info.inspect} for term #{msg.term} leader" }
			Message::VoteReply.new(term: @current_term, vote_granted: true)
		else
			logger.debug(logloc) { "Rejected #{msg.candidate_info.inspect} for term #{msg.term} leader; @current_term=#{@current_term} @voted_for=#{@voted_for.inspect} msg.last_log_index=#{msg.last_log_index} @log.last_index=#{@log.last_index} msg.last_log_term=#{msg.last_log_term} @log.last_entry_term=#{@log.last_entry_term}" }
			Message::VoteReply.new(term: @current_term, vote_granted: false)
		end
	end

	def process_read_request(msg, conn)
		if !leader?
			Message::ReadReply.new(success: false, leader_info: @leader_info)
		elsif @commit_index > msg.commit_index
			# We already *know* this is never going to succeed, may as well save ourselves
			# the hassle
			logger.debug(logloc) { "ReadRequest is for an out-of-date commit_index; nopeing out" }
			Message::ReadReply.new(success: false)
		elsif @config.nodes.length == 1
			# Flyin' solo!
			if @commit_index == msg.commit_index
				Message::ReadReply.new(success: true)
			else
				Message::ReadReply.new(success: false)
			end
		else
			responders = [node_info]

			issue_append_entries_to_cluster do |reply, node_info|
				# responders will be set to nil when quorum has been met, so all remaining
				# AE replies can be quietly ignored
				next if responders.nil?

				if reply.success
					responders << node_info
					logger.debug(logloc) { "Checking if #{responders.inspect} meets read request quorum" }
					if @config.quorum_met?(responders)
						logger.debug(logloc) { "Have met read request quorum; reply sent" }
						if @commit_index == msg.commit_index
							conn.send_reply(Message::ReadReply.new(success: true))
						else
							conn.send_reply(Message::ReadReply.new(success: false))
						end
						responders = nil
					else
						logger.debug(logloc) { "Not yet met read request quorum" }
					end
				end
			end

			# Deferred reply
			nil
		end
	end

	def process_install_snapshot_request(msg, conn)
		if msg.term < @current_term
			conn.send_reply(Message::InstallSnapshotReply.new(term: @current_term))
			return
		end

		@sm_mutex.synchronize do
			@state_machine = @state_machine_class.new(snapshot: msg.data)
			@log.new_snapshot(msg.last_included_term, msg.last_included_index)
			@commit_index = msg.last_included_index
		end

		conn.send_reply(Message::InstallSnapshotReply.new(term: @current_term))
	end

	def trigger_election
		new_term(@current_term + 1)
		logger.debug(logloc) { "Initiating election for term #{@current_term}" }
		become_candidate

		if @config.nodes.length == 1
			# Flyin' solo!
			logger.debug(logloc) { "No need for an election, as we're in single-node mode" }
			become_leader
		else
			election_term = @current_term
			electors = [node_info]
			@voted_for = node_info

			logger.debug(logloc) { "Canvassing the electorate" }
			@config.nodes.each do |n|
				next if n == node_info

				@async_task.async do
					logger.debug(logloc) { "Sending vote request to #{n.inspect}" }
					begin
						reply = @peers[n].rpc(Message::VoteRequest.new(term: election_term, candidate_info: node_info, last_log_index: @log.last_index, last_log_term: @log.last_entry_term))
					rescue => ex
						log_exception(ex) { "Failed to send vote to #{n.inspect}" }
						if @peers.key?(n)
							@peers[n].conn.close
							@peers.delete(n)
						end
						next
					end

					if electors.nil?
						# No need to process a vote if we're not running an election at the moment
						next
					end

					unless candidate?
						logger.debug(logloc) { "Received ballot from #{n.inspect}: #{reply.inspect} while in #{@mode} mode" }
						next
					end

					logger.debug(logloc) { "Processing vote #{reply.inspect} from #{n.inspect}" }
					if reply.nil?
						logger.debug(logloc) { "Received no reply to vote from #{n.inspect}" }
					elsif reply.term > @current_term
						logger.debug(logloc) { "Received higher term from #{n.inspect}; canceling election" }
						new_term(reply.term)
						become_follower
						electors = nil
					elsif reply.vote_granted
						logger.debug(logloc) { "Received the vote of #{n.inspect}" }
						electors << n

						logger.debug(logloc) { "Got #{electors.length} votes so far" }

						if @config.quorum_met?(electors)
							become_leader
							electors = nil
						end
					end
				end
			end
		end
	end
end

require_relative "./evinrude/backoff"
require_relative "./evinrude/config_change_queue_entry/add_node"
require_relative "./evinrude/config_change_queue_entry/remove_node"
require_relative "./evinrude/cluster_configuration"
require_relative "./evinrude/freedom_patches/range"
require_relative "./evinrude/log"
require_relative "./evinrude/log_entries"
require_relative "./evinrude/messages"
require_relative "./evinrude/metrics"
require_relative "./evinrude/network"
require_relative "./evinrude/node_info"
require_relative "./evinrude/peer"
require_relative "./evinrude/snapshot"
require_relative "./evinrude/state_machine/register"
