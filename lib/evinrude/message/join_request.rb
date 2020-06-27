require_relative "../message"
require_relative "./join_reply"

class Evinrude
	class Message
		class JoinRequest < Message
			attr_reader :node_info

			def initialize(node_info:)
				@node_info = node_info
			end

			def expected_reply_types
				[JoinReply]
			end
		end
	end
end
