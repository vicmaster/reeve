# frozen_string_literal: true

module Reeve
  module Testing
    module Matchers
      # FR-017, from RSpec:
      #
      #   it { is_expected.to audit_every_call }
      #   it { is_expected.to audit_every_call.for_principal(alice).with(query: "AC") }
      #
      # Point it at the host's own call site to prove that *that* goes through the
      # envelope, which is where an audit bypass actually lives:
      #
      #   it { is_expected.to audit_every_call.invoked_by(MyServer.method(:dispatch)) }
      class AuditEveryCall < Base
        def self.check
          Checks::AuditCoverage
        end

        def for_principal(principal)
          @principal = principal
          self
        end

        def description
          "audit every call"
        end

        private

        def check_for(tool)
          Checks::AuditCoverage.new(
            tool: tool, principal: @principal || default_principal, **options
          )
        end
      end
    end
  end
end
