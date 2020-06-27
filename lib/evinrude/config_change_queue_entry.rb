class Evinrude
	class ConfigChangeQueueEntry
		def initialize(msg, conn = nil)
			@msg, @conn = msg, conn
		end

		def node_info
			@msg.node_info
		end

		def send_successful_reply
			@conn.send_reply(reply_class.new(success: true))
		end

		def send_redirect_reply(leader_info)
			@conn.send_reply(reply_class.new(success: false, leader_info: leader_info))
		end
	end
end
