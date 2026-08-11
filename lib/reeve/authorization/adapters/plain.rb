# frozen_string_literal: true

module Reeve
  module Authorization
    module Adapters
      # Plain policy objects — always available, no dependency on anything.
      #
      #   class InvoicePolicy
      #     def self.authorize(principal, action, record) = ...
      #     def self.scope(principal, relation) = relation.where(owner: principal)
      #   end
      class Plain
        REQUIRED_METHODS = %i[authorize scope].freeze

        def self.supports?(policy)
          REQUIRED_METHODS.all? { |method| policy.respond_to?(method) }
        end

        def self.missing_methods(policy)
          REQUIRED_METHODS.reject { |method| policy.respond_to?(method) }
        end

        def authorize(principal:, policy:, action:, record: nil)
          rule = rule_for(policy, action)
          allowed = policy.authorize(principal, action, record)

          allowed ? Decision.allow(rule: rule) : Decision.deny(rule: rule)
        end

        def scope(principal:, policy:, relation:)
          scoped = policy.scope(principal, relation)
          return scoped unless scoped.nil?

          # A nil scope is a policy that did not answer. Answering "everything" would be
          # the dangerous reading, so this is an error rather than a fallback.
          raise Error, "#{rule_for(policy, :scope)} returned nil; a scope must return a relation"
        end

        def scope_rule(policy)
          rule_for(policy, :scope)
        end

        # A tool may return more than the type its declared policy governs. Rather than
        # denying every mixed result, reeve looks for the conventional `<Model>Policy`
        # for the other types — and denies when there is not one (unknown_record_type).
        def policy_for(record_class)
          name = "#{record_class.name}Policy"
          return nil unless Object.const_defined?(name)

          policy = Object.const_get(name)
          self.class.supports?(policy) ? policy : nil
        rescue NameError
          nil
        end

        private

        def rule_for(policy, action)
          name = policy.respond_to?(:name) && policy.name ? policy.name : policy.class.name
          "#{name}##{action}"
        end
      end
    end
  end
end
