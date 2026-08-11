# frozen_string_literal: true

require_relative "../reeve"
require_relative "testing/result"
require_relative "testing/report"
require_relative "testing/ledger"
require_relative "testing/checks"

module Reeve
  # The testing kit: framework-neutral checks, and thin front-ends over them.
  #
  #   require "reeve/testing"    # the checks, and nothing else
  #   require "reeve/rspec"      # + matchers and the shared example group
  #   require "reeve/minitest"   # + assertions and the compliance test case
  #
  # This file loads no test framework and no ActiveRecord, so the checks are runnable from
  # a rake task, a CI script or a boot-time assertion in staging (FR-020, FR-026):
  #
  #   require "reeve/testing"
  #   report = Reeve::Checks.run_all(principals: [alice, bob])
  #   abort report.to_s unless report.passed?
  module Testing
    class << self
      # The two fixture principals the compliance suite runs every tool against. Set once,
      # in the host's test helper, and both front-ends' compliance suites pick it up:
      #
      #   Reeve::Testing.compliance_principals = -> { [users(:alice), users(:bob)] }
      #
      # A callable rather than a value, because in a Rails test suite the fixtures do not
      # exist yet at the moment the helper is loaded.
      attr_writer :compliance_principals

      def compliance_principals
        source = @compliance_principals || Reeve.config.compliance_principals
        raise ConfigurationError, missing_principals_message if source.nil?

        principals = Array(source.respond_to?(:call) ? source.call : source)
        raise ConfigurationError, missing_principals_message if principals.size < 2

        principals
      end

      def compliance_principals?
        !(@compliance_principals || Reeve.config.compliance_principals).nil?
      end

      def reset!
        @compliance_principals = nil
      end

      private

      def missing_principals_message
        "the reeve compliance suite needs two fixture principals with disjoint records. " \
          "Set them in your test helper:\n\n  " \
          "Reeve::Testing.compliance_principals = -> { [users(:alice), users(:bob)] }"
      end
    end
  end
end
