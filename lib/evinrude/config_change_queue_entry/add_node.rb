require_relative "../config_change_queue_entry"

class Evinrude
	class ConfigChangeQueueEntry
		class AddNode < ConfigChangeQueueEntry
			private

			def reply_class
				Message::JoinReply
			end
		end
	end
end
