require_relative "../message"

class Evinrude
	class Message
		class CommandReply < Message
			attr_reader :success, :leader_info

			def initialize(success:, leader_info: nil)
				@success, @leader_info = success, leader_info
			end
		end
	end
end
