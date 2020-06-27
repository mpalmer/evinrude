require_relative "./message/append_entries_request"

class Evinrude
	class Peer
		attr_reader :conn, :next_index, :match_index, :node_info

		def initialize(conn:, next_index:, node_info:, metrics:)
			@conn, @next_index, @node_info, @metrics = conn, next_index, node_info, metrics
			@match_index = 0

			update_metrics
		end

		def failed_append(last_index = nil)
			if last_index
				@next_index = last_index + 1
			else
				@next_index = [1, @next_index - 1].max
			end

			update_metrics
		end

		def successful_append(last_index)
			@next_index  = last_index + 1
			@match_index = last_index

			update_metrics
		end

		def peer_info
			conn.peer_info
		end

		def node_name
			@node_info.name
		end

		def rpc(*a)
			conn.rpc(*a)
		end

		private

		def update_metrics
			@metrics.next_index.set(@next_index, labels: { peer: peer_info, node_name: @node_name })
			@metrics.match_index.set(0, labels: { peer: peer_info, node_name: @node_name })
		end
	end
end
