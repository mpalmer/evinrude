require "async/semaphore"
require "digest/sha2"
require "yaml"

require_relative "./protocol"

class Evinrude
	class Network
		class Connection
			include Evinrude::LoggingHelpers
			include Evinrude::Network::Protocol

			class ConnectionError < Error; end

			attr_reader :peer_address, :peer_port

			def self.connect(address:, port:, keys:, logger:, metrics:)
				backoff = Evinrude::Backoff.new

				begin
					sock = Async::IO::Endpoint.tcp(address, port).connect
				rescue Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT => ex
					logger.info("Evinrude::Network::Connection.connect") { "Could not connect to #{address}:#{port}: #{ex.class}" }
					raise ConnectionError,
					      "#{ex.class}"
				end

				new(socket: sock, logger: logger, metrics: metrics, keys: keys)
			end

			def initialize(socket:, logger:, metrics:, keys:)
				@socket, @logger, @metrics = socket, logger, metrics

				@keys = keys.map { |k| Digest::SHA256.digest(k) }

				@sem = Async::Semaphore.new

				@peer_address = @socket.remote_address.ip_address
				@peer_port    = @socket.remote_address.ip_port
			end

			def peer_info
				"#{peer_address}:#{peer_port}"
			end

			def rpc(msg)
				@metrics.rpc.measure(target: peer_info) do |labels|
					begin
						@sem.acquire do
							logger.debug(logloc) { "Sending RPC request #{msg.inspect} to #{peer_info}" }
							begin
								@socket.write(frame(box(msg.to_yaml)))
							rescue Errno::EPIPE, IOError, Errno::ECONNRESET => ex
								logger.debug(logloc) { "Failed to send RPC request to #{peer_info}: #{ex.message} (#{ex.class})" }
								labels[:result] = ex.class.to_s
								return nil
							end

							logger.debug(logloc) { "Request sent; now we wait" }

							begin
								read_message
							rescue Protocol::VersionError, Errno::ECONNRESET, Errno::EPIPE, IOError => ex
								logger.debug(logloc) { "I/O exception #{ex.class} while reading RPC reply" }
								labels[:result] = ex.class.to_s
								@socket.close
								nil
							end
						end.tap { labels[:result] = "success" }
					rescue Async::Wrapper::Cancelled
						labels[:result] = "cancelled"
						nil
					end
				end
			end

			def each_message
				begin
					loop do
						@sem.acquire do
							yield read_message
						end
					end
				rescue Async::Wrapper::Cancelled
					# This is fine
					nil
				rescue Evinrude::Error, SystemCallError, IOError => ex
					# This is... not so fine, but there's not much we can do about it
					log_exception(ex) { "Reading message" }
					@socket.close
					nil
				end
			end

			def send_reply(msg)
				@socket.write(frame(box(msg.to_yaml)))
			end

			def close
				@socket.close
			end

			def inspect
				"#<#{self.class}:0x#{object_id.to_s(16)} " +
					instance_variables.map do |iv|
						next nil if %i{@logger @metrics @socket}.include?(iv)
						"#{iv}=#{instance_variable_get(iv).inspect}"
					end.compact.join(" ")
			end

			private

			def read_message
				v = @socket.read(1)

				if v.nil?
					logger.debug(logloc) { "Connection to #{peer_info} closed" }
					raise Async::Wrapper::Cancelled
				end

				unless v == "\x00"
					raise Protocol::VersionError, "Expected 0, got #{v.inspect}"
				end

				lenlen = @socket.read(1).ord

				if (lenlen & 0x80) == 0
					len = lenlen
				else
					lenlen &= 0x7f
					len = @socket.read(lenlen).split(//).inject(0) { |a, c| a * 256 + c.ord }
				end

				if len > max_message_size
					raise MessageTooBigError
				end

				box = @socket.read(len)

				YAML.safe_load(unbox(box), permitted_classes: Message.classes + LogEntry.classes + [NodeInfo, ClusterConfiguration, Symbol], aliases: true)
			end
		end
	end
end
