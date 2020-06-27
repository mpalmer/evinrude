class Evinrude
	class LogEntry
		def self.classes
			Evinrude::LogEntry.constants.map { |c| Evinrude::LogEntry.const_get(c) }.select { |c| Class === c }
		end

		attr_reader :term

		def initialize(term:)
			@term = term
		end
	end
end
