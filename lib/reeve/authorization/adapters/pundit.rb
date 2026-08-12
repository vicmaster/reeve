# frozen_string_literal: true

module Reeve
  module Authorization
    module Adapters
      # Pundit policies, bridged rather than depended on. Pundit itself is never required
      # by this gem (Constitution IV); this file only speaks its conventions, and reports
      # that it supports nothing when Pundit is absent.
      #
      #   class InvoicePolicy
      #     def index? = ...
      #     class Scope < ApplicationPolicy::Scope
      #       def resolve = scope.where(owner: user)
      #     end
      #   end
      class Pundit
        def self.pundit_loaded?
          defined?(::Pundit) ? true : false
        end

        def self.supports?(policy)
          return false unless pundit_loaded?
          return false unless policy.is_a?(Class)

          scope_defined?(policy) &&
            policy.public_instance_methods.any? { |method| method.to_s.end_with?("?") }
        end

        # Pundit policies ordinarily inherit their Scope from a base policy
        # (`class LeadPolicy < LeadBasePolicy`), so asking only the policy's own namespace
        # rejected the common case. This walks the ancestry instead, stopping before
        # Object — which is the whole reason the check was narrow to begin with: a
        # top-level `Scope` constant must never make an unrelated class look
        # Pundit-shaped. `policy::Scope` resolves along the same ancestry, so what
        # `supports?` accepts is exactly what `scope` can later reach.
        def self.scope_defined?(policy)
          policy_ancestry(policy).any? { |ancestor| ancestor.const_defined?(:Scope, false) }
        end

        def self.policy_ancestry(policy)
          policy.ancestors.take_while { |ancestor| ancestor != Object }
        end

        def self.missing_methods(policy)
          return [] if supports?(policy)
          return [:Scope] if policy.is_a?(Class) && !scope_defined?(policy)

          %i[query_method Scope]
        end

        def authorize(principal:, policy:, action:, record: nil)
          query = "#{action}?"
          rule = "#{policy.name}##{query}"
          subject = record || inferred_subject(policy)

          if policy.new(principal,
                        subject).public_send(query)
            Decision.allow(rule: rule)
          else
            Decision.deny(rule: rule)
          end
        end

        def scope(principal:, policy:, relation:)
          scoped = policy::Scope.new(principal, relation).resolve
          return scoped unless scoped.nil?

          raise Error, "#{scope_rule(policy)} returned nil; a scope must return a relation"
        end

        def scope_rule(policy)
          "#{policy.name}::Scope"
        end

        # Pundit's own convention, which is what makes per-type scoping of a mixed result
        # possible at all: Invoice => InvoicePolicy.
        def policy_for(record_class)
          name = "#{record_class.name}Policy"
          Object.const_defined?(name) ? Object.const_get(name) : nil
        rescue NameError
          nil
        end

        private

        # Pundit policies are constructed with a record; for an index-style check there is
        # no record yet, so the class stands in — the same thing `authorize Invoice` does.
        def inferred_subject(policy)
          name = policy.name.to_s.sub(/Policy\z/, "")
          Object.const_defined?(name) ? Object.const_get(name) : nil
        rescue NameError
          nil
        end
      end
    end
  end
end
