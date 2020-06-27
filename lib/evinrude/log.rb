require "yaml"

class Evinrude
	class Log
		include Evinrude::LoggingHelpers

		class TruncationUnderflowError < Error; end
		class SnapshottedEntryError < Error; end

		attr_reader :snapshot_last_term, :snapshot_last_index

		def initialize(logger:, snapshot_last_term: 0, snapshot_last_index: 0)
			@logger, @snapshot_last_term, @snapshot_last_index = logger, snapshot_last_term, snapshot_last_index

			@entries = []
		end

		def append(entry)
			logger.debug(logloc) { "Appending new entry #{entry.inspect} as ##{@snapshot_last_index + @entries.length + 1}" }
			@entries << entry

			if @entries.length > 1000
				old_len = @entries.length
				snapshotted_entries = @entries[0..499]
				@entries = @entries[500..]
				@snapshot_last_index += 500
				@snapshot_last_term = snapshotted_entries.last.term
			end
		end

		def new_snapshot(last_term, last_index)
			@snapshot_last_term = last_term
			@snapshot_last_index = last_index

			@entries = []
		end

		def has_entry?(n)
			n == 0 || n <= @snapshot_last_index + @entries.length
		end

		def snapshotted_entry?(n)
			n > 0 && n <= @snapshot_last_index
		end

		def last_index
			@entries.length + @snapshot_last_index
		end

		def last_entry_term
			if @entries.empty?
				@snapshot_last_term
			else
				@entries.last.term
			end
		end

		def entry_term(n)
			if n == @snapshot_last_index
				@snapshot_last_term
			else
				self[n]&.term
			end
		end

		def entries_from(n)
			@entries[(n-@snapshot_last_index-1)..] || []
		end

		# Make the last entry kept in the log the nth.
		def truncate_to(n)
			if n > @snapshot_last_index
				@entries = @entries[0..n-@snapshot_last_index-1]
			elsif n == @snapshot_last_index
				@entries = []
			else
				raise TruncationUnderflowError,
				      "Cannot truncate to log entry ##{n}; into the snapshot"
			end
		end

		def [](n)
			if n == 0
				zeroth_log_entry
			elsif n <= @snapshot_last_index
				raise SnapshottedEntryError
			else
				@entries[n - @snapshot_last_index - 1]
			end
		end

		private

		def zeroth_log_entry
			@zeroth_log_entry ||= LogEntry::Null.new(term: 0)
		end

		def snapshot_log_entry
			@snapshot_log_entry ||= LogEntry::Null.new(term: @snapshot_last_term)
		end
	end
end
