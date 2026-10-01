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

      # The tools the suite walks. Unset means every tool reeve knows about — the classes
      # that included the DSL, guarded or not, plus every class the endpoint inventory
      # routes to, which need not have included anything. That default is what makes an
      # unguarded tool visible rather than merely absent.
      attr_writer :compliance_tools

      def compliance_tools
        source = @compliance_tools || Reeve.config.compliance_tools
        return Reeve.registry.tool_classes | inventory_tools if source.nil?

        Array(source.respond_to?(:call) ? source.call : source)
      end

      # The host said which tools it is certifying, so a run is a subset by its own account.
      def compliance_tools_narrowed?
        !(@compliance_tools || Reeve.config.compliance_tools).nil?
      end

      def compliance_principals?
        !(@compliance_principals || Reeve.config.compliance_principals).nil?
      end

      def reset!
        @compliance_principals = nil
        @compliance_tools = nil
      end

      private

      # An inventory that cannot be read adds nothing here; EndpointCoverage fails on it
      # by name, which is a better place to learn about it than an exception in every
      # per-tool check.
      def inventory_tools
        inventory = Reeve.config.inventory
        inventory ? inventory.routed_tools : []
      rescue StandardError
        []
      end

      def missing_principals_message
        "the reeve compliance suite needs two fixture principals with disjoint records. " \
          "Set them in your test helper:\n\n  " \
          "Reeve::Testing.compliance_principals = -> { [users(:alice), users(:bob)] }"
      end
    end
  end
end
