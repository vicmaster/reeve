# frozen_string_literal: true

# Reeve — per-record authorization and an append-only audit ledger for MCP tools.
module Reeve
  module Authorization
    # Every `guard_with` declaration in the process, keyed by tool class.
    #
    # Two lookups matter: by class, which the DSL and inheritance use, and by tool name,
    # which is all the envelope has. Enumeration is what lets the compliance suite ask the
    # question that matters — "is every tool this application exposes actually guarded?"
    class Registry
      include Enumerable

      def initialize
        @declarations = {}
        @name_index = nil # invalidated on every add; see #name_index
        @mutex = Mutex.new
      end

      def register(tool_class:, policy:, action: nil, redacted_arguments: [])
        declaration = Declaration.new(
          tool_class: tool_class,
          policy: policy,
          action: action || Reeve.config.default_action,
          redacted_arguments: redacted_arguments
        )
        add(declaration)
      end

      def add(declaration)
        @mutex.synchronize do
          warn_about_redeclaration(declaration) if @declarations.key?(declaration.tool_class)
          @declarations[declaration.tool_class] = declaration
          @name_index = nil
          declaration
        end
      end

      # Walks the ancestry, so a subclass inherits its parent's guard and may override it
      # simply by declaring its own.
      def for_class(tool_class)
        return nil unless tool_class.respond_to?(:ancestors)

        tool_class.ancestors.each do |ancestor|
          declaration = @declarations[ancestor]
          return declaration if declaration
        end
        nil
      end

      # The envelope's lookup. Returns nil for an unknown tool, which is a denial.
      def guard_for(tool_name)
        name_index[tool_name.to_s]
      end

      def each(&block)
        @declarations.values.each(&block)
      end

      def size
        @declarations.size
      end

      def empty?
        @declarations.empty?
      end

      def reset!
        @mutex.synchronize do
          @declarations = {}
          @name_index = nil
        end
      end

      private

      def name_index
        @name_index ||= @declarations.values.to_h do |declaration|
          [declaration.tool_name, declaration]
        end
      end

      def warn_about_redeclaration(declaration)
        message = "reeve: #{declaration.tool_class} declared guard_with more than once; " \
                  "the later declaration replaces the earlier one"
        logger = Reeve.config.logger
        logger ? logger.warn(message) : Kernel.warn(message)
      end
    end
  end

  class << self
    # The process-wide registry the DSL writes to.
    def registry
      @registry ||= Authorization::Registry.new
    end

    # Public so host test suites can isolate examples from one another.
    def reset_registry!
      registry.reset!
    end
  end
end
