# frozen_string_literal: true

module Reeve
  module Testing
    module Matchers
      # What every reeve matcher is: a check, and nothing else.
      #
      # +failure_message+ returns the check's own +message+ verbatim. No matcher composes
      # a sentence, reformats one, or adds context (FR-019) — that is the whole reason the
      # same violation reads identically here, in Minitest, and in a rake task.
      #
      # Written against RSpec's matcher protocol by duck-typing rather than by including
      # +RSpec::Matchers::DSL+, so nothing under lib/reeve/testing needs RSpec loaded in
      # order to be *parsed*; only a suite that uses these needs it present.
      class Base
        attr_reader :result

        def initialize
          @arguments = {}
          @invoke = nil
          @ledger = nil
        end

        # The arguments the tool is called with.
        def with(**arguments)
          @arguments = arguments
          self
        end

        # How the tool is called. Point this at a host's own invoker to prove that *it*
        # goes through the envelope.
        def invoked_by(callable)
          @invoke = callable
          self
        end

        def reading(ledger)
          @ledger = ledger
          self
        end

        def matches?(subject)
          @result = check_for(subject).call
          @result.passed?
        end

        # No `does_not_match?`: RSpec negates `matches?` for us, and a check that had a
        # separate negative path could drift from its positive one.
        def failure_message
          result.message
        end

        def failure_message_when_negated
          "expected #{result.check} to fail, but it passed: #{result.message}"
        end

        def description
          self.class.check.check_name
        end

        def supports_block_expectations?
          false
        end

        private

        attr_reader :arguments, :invoke, :ledger

        def check_for(_subject)
          raise NotImplementedError, "#{self.class} must build its check"
        end

        def options
          { arguments: arguments, invoke: invoke, ledger: ledger }
        end

        # The principal a matcher falls back to when the example did not name one.
        def default_principal
          Testing.compliance_principals.first
        end
      end
    end
  end
end
