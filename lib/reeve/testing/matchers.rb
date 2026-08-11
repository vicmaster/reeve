# frozen_string_literal: true

require_relative "matchers/base"
require_relative "matchers/deny_access_for"
require_relative "matchers/audit_every_call"
require_relative "matchers/pass_reeve_check"

module Reeve
  module Testing
    # The RSpec front-end.
    #
    #   require "reeve/rspec"
    #   RSpec.configure { |c| c.include Reeve::Testing::Matchers }
    #
    #   RSpec.describe InvoiceSearchTool do
    #     it { is_expected.to deny_access_for(stranger).with(query: "AC") }
    #     it { is_expected.to audit_every_call }
    #   end
    module Matchers
      def deny_access_for(principal)
        DenyAccessFor.new(principal)
      end

      def audit_every_call
        AuditEveryCall.new
      end

      def pass_reeve_check
        PassReeveCheck.new
      end
    end
  end
end
