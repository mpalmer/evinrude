require_relative "../message"

class Evinrude
	class Message
		class InstallSnapshotReply < Message
			attr_reader :term

			def initialize(term:)
				@term = term
			end
		end
	end
end
