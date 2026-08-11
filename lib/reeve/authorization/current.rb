# frozen_string_literal: true

module Reeve
  module Authorization
    # The invocation in progress on this thread.
    #
    # `scoped(Model)` is called from inside a tool body, which has no reference to the
    # envelope, so the envelope's caller publishes the state here and clears it in an
    # ensure. Fiber-local storage (Thread#[]) rather than thread-global, so concurrent
    # invocations — the normal case for an MCP server — cannot see each other's principal.
    module Current
      KEY = :reeve_current_invocation

      module_function

      def state
        Thread.current[KEY]
      end

      def start(context:, declaration:, adapter:)
        previous = state
        Thread.current[KEY] =
          State.new(context: context, declaration: declaration, adapter: adapter)
        previous
      end

      def finish(previous = nil)
        Thread.current[KEY] = previous
      end

      def with(context:, declaration:, adapter:)
        previous = start(context: context, declaration: declaration, adapter: adapter)
        yield(state)
      ensure
        finish(previous)
      end

      def active?
        !state.nil?
      end

      # Mutable for exactly two reasons: recording that `scoped` was used, and the size of
      # what it scoped. Everything else about an invocation is fixed when it starts.
      class State
        attr_reader :context, :declaration, :adapter
        attr_accessor :scoped_source_count

        def initialize(context:, declaration:, adapter:)
          @context = context
          @declaration = declaration
          @adapter = adapter
          @scoped_used = false
          @scoped_source_count = nil
        end

        def scoped_used!
          @scoped_used = true
        end

        def scoped_used?
          @scoped_used
        end
      end
    end
  end
end
