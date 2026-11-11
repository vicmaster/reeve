# frozen_string_literal: true

module Reeve
  module Integrations
    # The official MCP SDK bridge.
    module Mcp
      # Routes every SDK tool call through the envelope.
      #
      # The SDK calls a tool's class method, `tool.call(**arguments, server_context:)`, so
      # this is prepended to each tool's singleton class. That includes tools registered
      # as blocks: the SDK builds a class for each one (research R1 to R3).
      module ToolExtension
        def call(*args, **kwargs, &block)
          forwarded = reeve_forwardable(kwargs)
          return super(*args, **forwarded, &block) if Integrations.inside?(self)

          reeve_guarded(kwargs) { super(*args, **forwarded, &block) }
        end

        # How the testing kit runs this tool: as the server would, with no server context.
        # Inside the kit's envelope, so a denial raises instead of becoming a response.
        def reeve_run(arguments)
          return call(**arguments) unless reeve_takes_server_context?

          call(**arguments, server_context: nil)
        end

        private

        def reeve_guarded(kwargs, &body)
          Reeve.invoke(
            tool: self,
            arguments: kwargs.except(:server_context),
            **ContextBuilder.attributes(kwargs[:server_context]),
            &body
          )
        rescue DeniedError => e
          # A denial is a tool error in the SDK's own shape, carrying the rule and never a
          # record (FR-007). Anything else propagates, so the SDK reports it as it would
          # without reeve.
          ::MCP::Tool::Response.new([{ type: "text", text: e.message }], error: true)
        end

        # The SDK passes `server_context:` to any `call` that takes a `**` parameter, which
        # this one does. The tool still gets exactly what it got before (FR-020): the
        # keyword goes on only if the tool's own `call` would have received it.
        def reeve_forwardable(kwargs)
          return kwargs if reeve_takes_server_context? || !kwargs.key?(:server_context)

          kwargs.except(:server_context)
        end

        # The SDK's own rule, applied to the method this one wraps.
        def reeve_takes_server_context?
          method(:call).super_method.parameters.any? do |type, name|
            type == :keyrest || (name == :server_context && %i[key keyreq].include?(type))
          end
        end
      end

      # Installs the extension into every tool defined from here on, and gives tools the
      # class-level `scoped` and `authorize!` their body needs.
      module Inheritance
        def self.wrap(klass)
          return if Integrations.prepended?(klass.singleton_class, ToolExtension)

          klass.singleton_class.prepend(ToolExtension)
        end

        def inherited(subclass)
          super
          Inheritance.wrap(subclass)
        end
      end

      module_function

      def install!(tool_base = ::MCP::Tool)
        tool_base.extend(Reeve::Guard::Helpers)
        Integrations.install!(tool_base, Inheritance)
      end
    end
  end
end
