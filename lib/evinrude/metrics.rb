require "prometheus/client"
require "frankenstein"
require "frankenstein/remove_time_series"

class Evinrude
	class Metrics
		attr_reader :command_execution, :commit_index, :info, :joint_configuration,
		            :log_entries_persisted, :log_file_size, :log_loaded_from_disk,
		            :match_index, :messages_received, :next_index, :node_count,
		            :read_state, :remove_node, :replication_majority, :rpc,
		            :rpc_exception, :snapshot_file_size, :start_time, :state, :term

		def initialize(registry)
			@registry = registry

			@command_execution     = Frankenstein::Request.new(:evinrude_command, description: "state machine command", registry: @registry)
			@commit_index          = get_or_create(:gauge, :evinrude_commit_index, docstring: "The index of the last log entry committed to the state machine")
			@info                  = get_or_create(:gauge, :evinrude_node_info, docstring: "Basic information about this Evinrude node in labels", labels: %i{node_name listen_address listen_port advertise_address advertise_port})
			@joint_configuration   = get_or_create(:gauge, :evinrude_joint_configuration_action, docstring: "Whether or not this node is currently using a 'joint' configuration for consensus")
			@log_entries_persisted = get_or_create(:counter, :evinrude_log_entries_persisted_total, docstring: "How many log entries have been persisted to disk")
			@log_file_size         = get_or_create(:gauge, :evinrude_log_file_size_bytes, docstring: "The current size of the append-only log file")
			@log_loaded_from_disk  = get_or_create(:gauge, :evinrude_log_loaded_from_disk, docstring: "Whether (1) or not (0) this Evinrude node was initialized from data on disk")
			@match_index           = get_or_create(:gauge, :evinrude_follower_match_index, docstring: "The last log index known to be replicated to this follower", labels: %i{peer node_name})
			@messages_received     = get_or_create(:counter, :evinrude_messages_received_total, docstring: "How many unsolicited (RPC) messages have been received", labels: %i{type})
			@next_index            = get_or_create(:gauge, :evinrude_follower_next_index, docstring: "The index of the next log entry to be sent to a follower node", labels: %i{peer node_name})
			@node_count            = get_or_create(:gauge, :evinrude_node_count, docstring: "How many distinct nodes, active or otherwise, are currently in the cluster configuration")
			@read_state            = Frankenstein::Request.new(:evinrude_read_state, description: "read state check", registry: @registry)
			@remove_node           = Frankenstein::Request.new(:evinrude_remove_node, description: "remove node request", registry: @registry)
			@replication_majority  = get_or_create(:gauge, :evinrude_replication_majority_index, docstring: "The last log index that has been replicated to a majority of nodes")
			@rpc                   = Frankenstein::Request.new(:evinrude_rpc, description: "remote procedure call", registry: @registry, labels: %i{target}, duration_labels: %i{target result})
			@rpc_exception         = get_or_create(:counter, :evinrude_rpc_to_leader_exceptions_total, docstring: "How many exceptions have been raised whilst trying to do RPCs to the cluster leader", labels: %i{node_name target class})
			@snapshot_file_size    = get_or_create(:gauge, :evinrude_snapshot_file_size_bytes, docstring: "The current size of the snapshot data file")
			@start_time            = get_or_create(:gauge, :evinrude_node_start_time, docstring: "The number of seconds since the Unix epoch at which this Evinrude node commenced operation")
			@state                 = get_or_create(:gauge, :evinrude_node_state, docstring: "The current state of the node; 0=init, 1=candidate, 2=follower, 3=leader")
			@term                  = get_or_create(:gauge, :evinrude_current_term, docstring: "The current Raft election 'term' that this node is operating in")
		end

		def clear_peer_metrics
			[@match_index, @next_index, @replication_majority].each do |metric|
				metric.values.keys.each { |ls| metric.remove(ls) }
			end
		end

		private

		def get_or_create(type, name, docstring:, labels: [])
			@registry.get(name) || @registry.__send__(type, name, docstring: docstring, labels: labels)
		end
	end
end
