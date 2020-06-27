require_relative "../config_change_queue_entry"

class Evinrude
	class ConfigChangeQueueEntry
		class RemoveNode < ConfigChangeQueueEntry

			private

			def reply_class
				Message::NodeRemovalReply
			end
		end
	end
end
