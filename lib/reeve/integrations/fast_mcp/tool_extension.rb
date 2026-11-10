# frozen_string_literal: true

module Reeve
  module Integrations
    # The fast-mcp bridge: the DSL on every tool, and the envelope around every call.
    module FastMcp
      # Routes every fast-mcp tool call through the envelope.
      #
      # Prepended to each tool *subclass* rather than to `FastMcp::Tool` itself: a
      # prepended module precedes the class's own methods, but a module prepended to the
      # parent still sits behind the subclass's `call`. Prepending at `inherited` time
      # works even though `call` is defined afterwards, which is what makes this
      # impossible to forget — there is no "remember to wrap your tool" step.
      module ToolExtension
        def call(**arguments)
          attributes = ContextBuilder.attributes(self)

          Reeve.invoke(
            tool: self.class,
            arguments: arguments,
            agent: attributes[:agent],
            metadata: attributes[:metadata]
          ) { super(**arguments) }
        end
      end

      # Installs the extension into every tool defined from here on.
      module Inheritance
        def self.wrap(klass)
          klass.prepend(ToolExtension) unless Integrations.prepended?(klass, ToolExtension)
        end

        def inherited(subclass)
          super
          Inheritance.wrap(subclass)
        end
      end

      module_function

      # Idempotent: requiring "reeve/fast_mcp" twice must not stack two envelopes around
      # the same call.
      def install!(tool_base = ::FastMcp::Tool)
        Integrations.install!(tool_base, Inheritance)
      end
    end
  end
end
