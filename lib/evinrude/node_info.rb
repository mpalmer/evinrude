class Evinrude
	class NodeInfo
		attr_reader :name, :address, :port

		def initialize(address:, port:, name:)
			@address, @port, @name = address, port, name
		end

		# It's useful for a NodeInfo to be able to be treated like a hash sometimes.
		def [](k)
			case k
			when :address
				@address
			when :port
				@port
			when :name
				@name
			else
				raise ArgumentError, "Invalid key #k.inspect}"
			end
		end

		def eql?(o)
			# I know hash equality doesn't mean "equality of hashes", but it amuses
			# me nonetheless that that is a good way to implement it.
			[Evinrude::NodeInfo, Hash].include?(o.class) && { address: @address, port: @port, name: @name}.eql?({ address: o[:address], port: o[:port], name: o[:name] })
		end

		alias :== :eql?

		def hash
			{ address: @address, port: @port, name: @name }.hash
		end
	end
end
