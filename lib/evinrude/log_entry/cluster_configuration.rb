require_relative "../log_entry"

class Evinrude
	class LogEntry
		class ClusterConfiguration < LogEntry
			attr_reader :config

			def initialize(term:, config:)
				super(term: term)

				@config = config
			end
		end
	end
end
