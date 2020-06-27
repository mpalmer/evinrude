require_relative "../message"

class Evinrude
	class Message
		class AppendEntriesReply < Message
			attr_reader :term, :success, :last_index

			def initialize(term:, success:, last_index: nil)
				@term, @success, @last_index = term, success, last_index
			end
		end
	end
end
