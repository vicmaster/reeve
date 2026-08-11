# frozen_string_literal: true

module Reeve
  module Testing
    module Matchers
      # FR-016, from RSpec:
      #
      #   it { is_expected.to deny_access_for(stranger).with(query: "AC") }
      #
      # Backed by CrossPrincipalLeak in its :nothing expectation — this principal may
      # receive no record at all. A denial satisfies it; so does an allowed call that
      # returns an empty scope, because from the agent's side those are the same thing,
      # and FR-006 requires that they stay the same thing.
      class DenyAccessFor < Base
        def self.check
          Checks::CrossPrincipalLeak
        end

        def initialize(principal)
          super()
          @principal = principal
        end

        def description
          "deny access for #{@principal.inspect}"
        end

        private

        def check_for(tool)
          Checks::CrossPrincipalLeak.new(
            tool: tool, principals: [@principal], expect: :nothing, **options
          )
        end
      end
    end
  end
end
