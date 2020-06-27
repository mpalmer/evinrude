require_relative "../message"
require_relative "./install_snapshot_reply"

class Evinrude
	class Message
		class InstallSnapshotRequest < Message
			attr_reader :term, :leader_info, :last_included_index, :last_included_term, :data

			def initialize(term:, leader_info:, last_included_index:, last_included_term:, data:)
				@term, @leader_info, @last_included_index, @last_included_term, @data = term, leader_info, last_included_index, last_included_term, data
			end

			def expected_reply_types
				[InstallSnapshotReply]
			end
		end
	end
end
