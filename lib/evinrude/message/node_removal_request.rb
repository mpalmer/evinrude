require_relative "../message"
require_relative "./node_removal_reply"

class Evinrude
	class Message
		class NodeRemovalRequest < Message
			attr_reader :node_info, :unsafe

			def initialize(node_info:, unsafe: false)
				@node_info, @unsafe = node_info, unsafe
			end

			def expected_reply_types
				[NodeRemovalReply]
			end
		end
	end
end
