require_relative "../message"
require_relative "./command_reply"

class Evinrude
	class Message
		class CommandRequest < Message
			attr_reader :command, :id, :node_name

			def initialize(command:, id:, node_name:)
				@command, @id, @node_name = command, id, node_name
			end

			def expected_reply_types
				[CommandReply]
			end
		end
	end
end
