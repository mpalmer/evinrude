require "async/io"
require "socket"

require_relative "./message/join_request"
require_relative "./network/connection"

class Evinrude
	class Network
		class ConnectionTimeoutError < Error; end

		include Evinrude::LoggingHelpers

		def initialize(keys:, logger:, metrics:, listen:, advertise:)
			@keys, @logger, @metrics, @advertise, @listen = keys, logger, metrics, advertise, listen

			@endpoint = Async::IO::Endpoint.tcp(@listen[:address], @listen[:port])
		end

		def start
			@socket = @endpoint.bind.first
			@socket.listen(Socket::SOMAXCONN)
			self
		end

		def advertised_address
			@advertise[:address] ||
			(
				Socket.ip_address_list.select { |a| a.ipv6? && !a.ipv6_loopback? && !a.ipv6_linklocal? }.first ||
				Socket.ip_address_list.select { |a| a.ipv4? && !a.ipv4_loopback? }.first
			).ip_address
		end

		def advertised_port
			@advertise[:port] ||
			@socket&.instance_variable_get(:@io)&.local_address&.ip_port
		end

		def listen_address
			@listen[:address]
		end

		def listen_port
			@listen[:port] == 0 ? advertised_port : @listen[:port]
		end

		def each_message(&blk)
			unless @socket
				bind
			end

			@socket.listen(Socket::SOMAXCONN)

			@socket.accept_each do |sock|
				conn = Network::Connection.new(socket: sock, keys: @keys, logger: logger, metrics: @metrics)

				conn.each_message do |msg|
					blk.call(msg, conn)
				end
			end
		end

		def connect(address:, port:)
			Connection.connect(address: address, port: port, keys: @keys, logger: logger, metrics: @metrics).tap do |conn|
				logger.debug(logloc) { "New connection #{conn} to #{address}:#{port}" }
				yield conn if block_given?
			end
		end
	end
end
