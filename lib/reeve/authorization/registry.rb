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
        @known = {}     # every class that included Guard, declared or not
        @abstract = {}  # bases others inherit from; not tools themselves
        @name_index = nil # invalidated on every add; see #name_index
        @mutex = Mutex.new
      end

      # A class that included the DSL. Recorded whether or not it goes on to declare
      # anything, because a tool that forgot `guard_with` is precisely the one worth
      # finding, and it is absent from `@declarations` by definition.
      def note(tool_class)
        @mutex.synchronize { @known[tool_class] = true }
        tool_class
      end

      # A base others inherit from — `FastMcp::Tool`, or a host's own `ApplicationTool`.
      # It acquires the DSL so its subclasses have it, and it is not itself a tool, so
      # asking whether it declared a guard is a question with no useful answer.
      #
      # Explicit rather than inferred. The obvious heuristic — "a class something else
      # inherits from is a base" — silently drops a real tool from the compliance run the
      # moment someone subclasses it, and a check that quietly stops checking is the
      # failure mode this whole file exists to prevent.
      def mark_abstract(tool_class)
        @mutex.synchronize { @abstract[tool_class] = true }
        tool_class
      end

      def abstract?(tool_class)
        @abstract.key?(tool_class)
      end

      # Every tool reeve knows about: the ones that declared a guard and the ones that
      # only included the DSL. This is what the compliance suite walks, so that "all
      # checks passed" cannot mean "we only looked at the tools that were already safe".
      def tool_classes
        (@known.keys | @declarations.keys).reject { |klass| abstract?(klass) }
      end

      # The worklist.
      def unguarded_tool_classes
        tool_classes.reject { |klass| @declarations.key?(klass) }
      end

      # The DSL's `guard_with`. Declaring twice on one class is a mistake worth naming;
      # `add` is the quiet path used by `redact` and by inheritance, which refine an
      # existing declaration rather than compete with it.
      def register(tool_class:, policy:, action: nil, redacted_arguments: [])
        warn_about_redeclaration_of(tool_class)

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

      # Forgets one tool. Test suites build throwaway tools, and the compliance suite
      # walks this registry — a fixture left behind fails a later, unrelated example.
      def remove(tool_class)
        @mutex.synchronize do
          @declarations.delete(tool_class)
          @known.delete(tool_class)
          @abstract.delete(tool_class)
          @name_index = nil
        end
      end

      def reset!
        @mutex.synchronize do
          @declarations = {}
          @known = {}
          @abstract = {}
          @name_index = nil
        end
      end

      private

      def name_index
        @name_index ||= @declarations.values.to_h do |declaration|
          [declaration.tool_name, declaration]
        end
      end

      def warn_about_redeclaration_of(tool_class)
        return unless @declarations.key?(tool_class)

        message = "reeve: #{tool_class} declared guard_with more than once; " \
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
