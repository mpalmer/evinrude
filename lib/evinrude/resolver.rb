require "async/dns"
require "async/dns/system"

class Evinrude
	class Resolver
		def initialize
			@config = Config.new
			p @config
			@resolver = Async::DNS::Resolver.new(Async::DNS::System.standard_connections(@config.nameservers))
		end

		def getaddresses(name)
			(getresources(name, Resolv::DNS::Resource::IN::AAAA) + getresources(name, Resolv::DNS::Resource::IN::A)).map(&:address).map(&:to_s)
		end

		def getresources(name, rtype)
			search_candidates(name).each do |fqdn|
				response = @resolver.query(fqdn, rtype)

				if response.rcode != Resolv::DNS::RCode::NoError
					next
				end

				return response.answer.map { |rr| rr[2] }
			end

			[]
		end

		private

		def search_candidates(name)
			ndots = name.each_char.grep(".").length

			if ndots >= @config.ndots
				[name] + @config.search_suffixes.map { |ss| "#{name}.#{ss}" }
			else
				@config.search_suffixes.map { |ss| "#{name}.#{ss}" }
			end
		end

		class Config
			attr_reader :search_suffixes, :nameservers, :ndots

			def initialize
				@ndots = 1

				if Object.const_defined?(:Win32)
					# Taking a punt here
					@search_suffixes, @nameservers = Win32::Resolv.get_resolv_info
				else
					if File.exist?(Async::DNS::System::RESOLV_CONF)
						parse_resolv_conf(Async::DNS::System::RESOLV_CONF)
					else
						raise ArgumentError, "resolver config file #{Async::DNS::System::RESOLV_CONF} does not exist"
					end
				end
			end

			private

			def parse_resolv_conf(filename)
				@nameservers = []

				File.open(filename) do |fd|
					fd.each_line do |l|
						case l
						when /^domain\s+(.*)$/
							@search_suffixes = [$1] if @search_suffixes.nil?
						when /^search\s+(.*)$/
							@search_suffixes = $1.split(/\s+/)
						when /^nameserver\s+(.*)$/
							@nameservers += $1.split(/\s+/)
						when /^options\s+(.*)$/
							$1.split(/\s+/).each do |opt|
								if opt =~ /ndots:(\d+)/
									@ndots = $1.to_i
								end
							end
						end
					end
				end

				if @search_suffixes.nil?
					@search_suffixes = [Socket.gethostname.split(".", 2)[1].to_s]
				end
			end
		end

		private_constant :Config
	end
end




