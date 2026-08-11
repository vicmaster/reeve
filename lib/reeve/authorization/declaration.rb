# frozen_string_literal: true

module Reeve
  module Authorization
    # What `guard_with` records for one tool class: which policy governs it, which action
    # to check, and which of its arguments never reach the ledger in the clear.
    class Declaration
      attr_reader :tool_class, :policy, :action, :redacted_arguments

      def initialize(tool_class:, policy:, action:, redacted_arguments: [])
        @tool_class = tool_class
        @policy = policy
        @action = action.to_sym
        @redacted_arguments = redacted_arguments.map(&:to_sym).freeze
      end

      # Resolved on first use rather than at construction: `guard_with` runs inside the
      # class body, and a class defined as `Class.new { ... }` has no name until the
      # constant it is assigned to exists.
      def tool_name
        @tool_name ||= derive_tool_name
      end

      def with(policy: self.policy, action: self.action,
               redacted_arguments: self.redacted_arguments)
        self.class.new(
          tool_class: tool_class, policy: policy, action: action,
          redacted_arguments: redacted_arguments
        )
      end

      def for_subclass(subclass)
        self.class.new(
          tool_class: subclass, policy: policy, action: action,
          redacted_arguments: redacted_arguments
        )
      end

      def policy_name
        policy.respond_to?(:name) && policy.name ? policy.name : policy.class.name
      end

      private

      # The name the envelope looks a guard up by. MCP server libraries let a tool name
      # itself; when it does, that name wins, because that is the name the protocol —
      # and therefore the ledger — will use.
      def derive_tool_name
        declared = tool_class.respond_to?(:tool_name) ? tool_class.tool_name : nil
        return declared.to_s unless declared.nil? || declared.to_s.empty?

        name = tool_class.name
        if name.nil? || name.empty?
          raise ConfigurationError,
                "#{tool_class.inspect} has no name, so reeve cannot identify it in the " \
                "ledger. Assign it to a constant, or define `def self.tool_name`."
        end

        underscore(name)
      end

      # ActiveSupport is not a dependency of the core, so this is deliberately small:
      # it handles the CamelCase and Namespaced::CamelCase shapes tool classes actually
      # have, and nothing more.
      def underscore(name)
        name.gsub("::", "_")
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .downcase
      end
    end
  end
end
