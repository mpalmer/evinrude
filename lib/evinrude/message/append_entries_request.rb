require_relative "../message"
require_relative "./append_entries_reply"

class Evinrude
	class Message
		class AppendEntriesRequest < Message
			attr_reader :term, :leader_info, :leader_commit, :prev_log_index, :prev_log_term, :entries

			def initialize(term:, leader_info:, leader_commit:, prev_log_index:, prev_log_term:, entries:)
				@term, @leader_info, @leader_commit, @prev_log_index, @prev_log_term, @entries = term, leader_info, leader_commit, prev_log_index, prev_log_term, entries
			end

			def expected_reply_types
				[AppendEntriesReply]
			end
		end
	end
end
