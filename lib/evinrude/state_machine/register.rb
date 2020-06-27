require_relative "../state_machine"

class Evinrude
	class StateMachine
		class Register < StateMachine
			def initialize(**kwargs)
				super

				@state = kwargs.fetch(:snapshot, "")
			end

			def process_command(s)
				@state = s
			end

			def current_state
				@state
			end

			def snapshot
				@state
			end
		end
	end
end
