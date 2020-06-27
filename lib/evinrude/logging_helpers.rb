# frozen_string_literal: true

require "logger"

class Evinrude
	module LoggingHelpers
		private

		def logger
			@logger || Logger.new("/dev/null")
		end

		def logloc
			loc = caller_locations.first
			"#{self.class}##{loc.label}"
		end

		def log_exception(ex, progname = nil)
			progname ||= "#{self.class.to_s}##{caller_locations(2, 1).first.label}"

			logger.error(progname) do
				explanation = if block_given?
					yield
				else
					nil
				end

				format_backtrace("#{explanation}#{explanation ? ": " : ""}#{ex.message} (#{ex.class})", ex.backtrace)
			end
		end

		def with_backtrace(msg)
			format_backtrace(msg, caller[1..])
		end

		def format_backtrace(msg, backtrace)
			([msg] + backtrace).join("\n  ")
		end
	end
end
