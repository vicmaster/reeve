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
        def inherited(subclass)
          super
          subclass.prepend(ToolExtension)
        end
      end

      module_function

      # Idempotent: requiring "reeve/fast_mcp" twice must not stack two envelopes around
      # the same call.
      def install!(tool_base = ::FastMcp::Tool)
        tool_base.include(Reeve::Guard) unless tool_base.include?(Reeve::Guard)

        unless tool_base.singleton_class.include?(Inheritance)
          tool_base.singleton_class.prepend(Inheritance)
        end

        # Tools defined before this require still get the envelope.
        tool_base.subclasses.each do |subclass|
          subclass.prepend(ToolExtension) unless subclass.include?(ToolExtension)
        end

        tool_base
      end
    end
  end
end
