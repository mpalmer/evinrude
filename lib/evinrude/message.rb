require "yaml"

class Evinrude
	class Message
		class ParseError < Evinrude::Error; end

		def self.parse(m)
			YAML.safe_load(m, permitted_classes: Evinrude::Message.permitted_classes, aliases: true)
		end

		def self.permitted_classes
			Evinrude::Message.classes + Evinrude::LogEntry.classes +	[Evinrude::NodeInfo, Evinrude::ClusterConfiguration, Symbol]
		end

		def self.classes
			Evinrude::Message.constants.map { |c| Evinrude::Message.const_get(c) }.select { |c| Class === c }
		end
	end
end
