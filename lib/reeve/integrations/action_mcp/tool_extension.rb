# frozen_string_literal: true

module Reeve
  module Integrations
    # The ActionMCP bridge.
    module ActionMcp
      # Routes every ActionMCP tool call through the envelope.
      #
      # ActionMCP's `call` rescues every error a tool raises and turns it into a generic
      # message, so the envelope sits inside it, around `perform`: a tool error or a denial
      # reaches the ledger before ActionMCP replaces it (FR-030). Whatever the tool renders
      # goes to a buffer, released to the real response only if the call is allowed
      # (FR-031). This reaches into ActionMCP's internals (`@response`, the protected
      # `perform`), which is why the adapter refuses versions it was not verified against.
      module ToolExtension
        # How the testing kit runs this tool: through ActionMCP's callbacks, with no rescue,
        # so a denial or an error reaches the kit's envelope.
        def reeve_perform
          @response = ::ActionMCP::ToolResponse.new
          run_callbacks(:perform) { perform }
          @response
        end

        protected

        def perform
          return super if Integrations.inside?(self.class)

          real = @response
          @response = ::ActionMCP::ToolResponse.new
          begin
            buffer = Reeve.invoke(tool: self.class, **ContextBuilder.attributes(self)) do
              super
              @response
            end
            ActionMcp.release(buffer, into: real)
          rescue DeniedError => e
            real.report_tool_error(e.message)
          ensure
            @response = real
          end
        end
      end

      # Installs the extension into every tool defined from here on, and keeps ActionMCP's
      # abstract bases out of the compliance suite.
      module Inheritance
        def self.wrap(klass)
          klass.prepend(ToolExtension) unless Integrations.prepended?(klass, ToolExtension)
        end

        def inherited(subclass)
          super
          Inheritance.wrap(subclass)
        end

        # `ApplicationMCPTool` and its kind call `abstract!`: a base, not a tool (R12).
        def abstract!
          super
          reeve_abstract!
        end

        def reeve_run(arguments)
          tool = from_wire(arguments.deep_stringify_keys)
          unless tool.valid?
            raise ArgumentError,
                  "#{tool_name}: invalid input: #{tool.errors.full_messages.join(', ')}"
          end

          tool.reeve_perform
        end
      end

      module_function

      def install!(tool_base = ::ActionMCP::Tool)
        Integrations.install!(tool_base, Inheritance)
        Integrations.descendants(tool_base).each do |klass|
          klass.reeve_abstract! if klass.abstract?
        end
        tool_base
      end

      # The allowed call's content, structured content and any error the tool reported on
      # itself, moved from the buffer to the response ActionMCP returns.
      def release(buffer, into:)
        buffer.contents.each { |content| into.add(content) }
        into.set_structured_content(buffer.structured_content) unless buffer.structured_content.nil?
        into.instance_variable_set(:@tool_execution_error, true) if buffer.tool_execution_error
        into
      end
    end
  end
end
