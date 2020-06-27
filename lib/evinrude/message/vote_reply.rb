require_relative "../message"

class Evinrude
	class Message
		class VoteReply < Message
			attr_reader :term, :vote_granted

			def initialize(term:, vote_granted:)
				@term, @vote_granted = term, vote_granted
			end
		end
	end
end
