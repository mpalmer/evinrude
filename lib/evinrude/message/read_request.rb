require_relative "../message"
require_relative "./read_reply"

class Evinrude
	class Message
		class ReadRequest < Message
			attr_reader :commit_index

			def initialize(commit_index:)
				@commit_index = commit_index
			end

			def expected_reply_types
				[ReadReply]
			end
		end
	end
end
