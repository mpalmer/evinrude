require "rbnacl"

class Evinrude
	class Network
		module Protocol
			class VersionError < Error; end
			class DecryptionError < Error; end

			class MessageTooBigError < Error; end

			private

			def max_message_size
				@max_message_size ||= begin
					if File.exist?("/proc/meminfo")
						File.read("/proc/meminfo").split("\n").map do |l|
							if l =~ /^MemTotal:\s+(\d+)\s+kB/
								$1.to_i * 1024 / 10
							else
								nil
							end
						end.compact.first
					else
						100_000_000
					end
				end
			end

			def box(msg)
				logger.debug(logloc) { "Encrypting message #{msg.inspect} with key #{@keys.first.inspect}" }
				RbNaCl::SimpleBox.from_secret_key(@keys.first).encrypt(msg)
			end

			def frame(chunk)
				"\x00" + encode_length(chunk.length) + chunk
			end

			def unbox(ciphertext)
				@keys.each do |k|
					begin
						return RbNaCl::SimpleBox.from_secret_key(k).decrypt(ciphertext)
					rescue RbNaCl::CryptoError
						# This just means "key failed"; nothing to get upset about
						logger.debug(logloc) { "Decryption of #{ciphertext.inspect} failed with key #{k.inspect}" }
					end
				end

				# ... but if all the keys fail, *that's* something to get upset about
				raise DecryptionError,
				      "Received an undecryptable message from #{peer_info}: #{ciphertext[0, 20].inspect}..."
			end

			def encode_length(i)
				if i < 128
					return i.chr
				else
					s = ""

					while i > 0
						s << (i % 256).chr
						i /= 256
					end

					(0x80 + s.length).chr + s.reverse
				end
			end
		end
	end
end
