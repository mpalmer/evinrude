require_relative "../message"
require_relative "./vote_reply"

class Evinrude
	class Message
		class VoteRequest < Message
			attr_reader :term, :candidate_info, :last_log_index, :last_log_term

			def initialize(term:, candidate_info:, last_log_index:, last_log_term:)
				@term, @candidate_info, @last_log_index, @last_log_term = term, candidate_info, last_log_index, last_log_term
			end

			def expected_reply_types
				[VoteReply]
			end
		end
	end
end
