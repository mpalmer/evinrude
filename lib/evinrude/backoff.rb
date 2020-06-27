class Evinrude
	class Backoff
		def initialize(slot_time: 0.5, max_slots: 30)
			@slot_time, @max_slots = slot_time, max_slots

			@fail_count = 0
		end

		def wait_time
			@fail_count += 1

			[2 ** @fail_count, @max_slots].min * rand * @slot_time
		end

		def wait
			sleep wait_time
		end
	end
end
