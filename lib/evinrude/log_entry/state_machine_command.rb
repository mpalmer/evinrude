class Evinrude
	class LogEntry
		class StateMachineCommand < LogEntry
			attr_reader :command, :id, :node_name

			def initialize(term:, command:, id:, node_name:)
				super(term: term)

				@command, @id, @node_name = command, id, node_name
			end
		end
	end
end
