class Evinrude
	class Snapshot
		attr_reader :node_name, :state, :cluster_config, :cluster_config_index, :last_term, :last_index, :last_command_ids

		def initialize(node_name:, state:, cluster_config:, cluster_config_index:, last_term:, last_index:, last_command_ids:)
			@node_name, @state, @cluster_config, @cluster_config_index, @last_term, @last_index, @last_command_ids = node_name, state, cluster_config, cluster_config_index, last_term, last_index, last_command_ids
		end
	end
end
