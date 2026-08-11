# frozen_string_literal: true

module Reeve
  module Audit
    # Removes declared-sensitive values from the arguments before they are written
    # (FR-011).
    #
    # Names always survive: an entry that cannot say *which* argument was passed answers
    # nothing after an incident. Values of declared names are replaced, recursively,
    # wherever they appear. Matching is on the name, never on the value — pattern-sniffing
    # a compliance artifact both misses and over-matches (R6).
    #
    # The input is never mutated and never stored: the redacted hash is a new structure,
    # so no unredacted copy exists downstream of this object.
    class Redactor
      MARKER = "[REDACTED]"

      # The names declared globally, plus the ones this tool's own guard declared.
      def self.for(tool_name, config: Reeve.config, registry: Audit.guard_registry)
        new(Array(config.redact_arguments) + tool_names(tool_name, registry))
      end

      def self.tool_names(tool_name, registry)
        return [] unless registry.respond_to?(:guard_for)

        guard = registry.guard_for(tool_name)
        return [] unless guard.respond_to?(:redacted_arguments)

        Array(guard.redacted_arguments)
      end
      private_class_method :tool_names

      def initialize(names, marker: MARKER)
        @names  = Array(names).map { |name| name.to_s.downcase }.uniq.freeze
        @marker = marker
      end

      def call(arguments)
        return {} if arguments.nil?

        redact_hash(arguments)
      end

      private

      attr_reader :names, :marker

      def redact_hash(hash)
        hash.each_with_object({}) do |(key, value), result|
          result[key] = sensitive?(key) ? marker : redact(value)
        end
      end

      def redact(value)
        case value
        when Hash  then redact_hash(value)
        when Array then value.map { |element| redact(element) }
        else value
        end
      end

      def sensitive?(key)
        names.include?(key.to_s.downcase)
      end
    end
  end
end
