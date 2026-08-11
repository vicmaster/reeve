# frozen_string_literal: true

module Reeve
  module Testing
    module Matchers
      # The escape hatch that keeps SC-009 honest: every one of the seven checks is
      # assertable from RSpec, not only the two with names of their own.
      #
      #   expect(Reeve::Checks::RedactionHolds.new(tool: T, principal: alice))
      #     .to pass_reeve_check
      class PassReeveCheck < Base
        def self.check
          Checks::Base
        end

        def description
          "pass its reeve check"
        end

        def failure_message_when_negated
          "expected #{result.check} to fail, but it passed: #{result.message}"
        end

        private

        def check_for(check)
          check
        end
      end
    end
  end
end
