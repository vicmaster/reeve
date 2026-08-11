# frozen_string_literal: true

module Reeve
  module Authorization
    # Narrows whatever a tool returned to what the principal may actually see, and reports
    # what it narrowed for the ledger. Every row of the return-value table in
    # contracts/tool-dsl.md is one branch of `scope`.
    #
    # The envelope reads records out of this result rather than out of the tool's return
    # value, so "nothing is returned without being scoped" is structural.
    class Scoper
      # Called by `Reeve::Guard#scoped` from inside a tool body. Marks the invocation as
      # having asked for a scoped relation, which is what makes a derived return value
      # (a count, a sum) safe to allow.
      def self.scoped_relation(state, model_or_relation)
        adapter = state.adapter
        declaration = state.declaration
        policy = policy_for(adapter, declaration, model_class(model_or_relation))
        raise Error, "no policy for #{model_or_relation.inspect}" if policy.nil?

        relation = model_or_relation.respond_to?(:all) ? model_or_relation.all : model_or_relation
        scoped = adapter.scope(principal: state.context.principal, policy: policy,
                               relation: relation)

        state.scoped_used!
        state.scoped_source_count = countable_size(scoped)
        scoped
      end

      # The declared policy governs, full stop — a declaration is an instruction, not a
      # hint. Only a result mixing several types needs more than one policy, and only the
      # types the declaration is *not* named for are resolved by convention; a type with
      # no policy denies the call (unknown_record_type).
      #
      # Inferring a policy from the record's class in the single-type case would mean a
      # tool declaring `guard_with LeakyPolicy` was silently enforced by `InvoicePolicy`:
      # the guard the developer declared would not be the guard that ran.
      def self.policy_for(adapter, declaration, record_class)
        return declaration.policy if record_class.nil?
        return declaration.policy unless declared_for_other_type?(declaration, record_class)

        adapter.policy_for(record_class) || nil
      end

      # True only when the declaration names a *different* model that actually exists —
      # `InvoicePolicy` on a tool that also returned `Memo`s. A policy whose name matches
      # no model (`LeakyPolicy`, `ApplicationPolicy`) is generic, and governs whatever the
      # tool it was declared on returns.
      def self.declared_for_other_type?(declaration, record_class)
        named = declaration.policy_name.to_s.sub(/Policy\z/, "")
        return false if named.empty? || named == record_class.name.to_s

        Object.const_defined?(named)
      rescue NameError
        false
      end

      def self.model_class(model_or_relation)
        return model_or_relation if model_or_relation.is_a?(Class)
        return model_or_relation.klass if model_or_relation.respond_to?(:klass)

        model_or_relation.class
      end

      def self.countable_size(scoped)
        scoped.respond_to?(:count) ? scoped.count : nil
      rescue StandardError
        nil
      end

      def scope(context:, guard:, result:)
        state = Current.state
        adapter = state ? state.adapter : Adapter.resolve(guard.policy)

        case result
        when nil then ScopeResult.allow(records: result, record_count: 0)
        else dispatch(context: context, guard: guard, result: result, adapter: adapter,
                      state: state)
        end
      end

      private

      def dispatch(context:, guard:, result:, adapter:, state:)
        if relation?(result)
          scope_relation(context, guard, result, adapter)
        elsif result.is_a?(Array)
          scope_array(context, guard, result, adapter)
        elsif record?(result)
          scope_single_record(context, guard, result, adapter)
        else
          scope_derived(result, state)
        end
      end

      def scope_relation(context, guard, relation, adapter)
        policy = policy_for!(adapter, guard, relation_class(relation))
        return unpoliced(relation_class(relation)) if policy.nil?

        scoped = adapter.scope(principal: context.principal, policy: policy, relation: relation)
        allow_records(scoped, relation_class(relation).name, record_ids(scoped))
      end

      def scope_array(context, guard, records, adapter)
        return ScopeResult.allow(records: [], record_count: 0) if records.empty?
        return scope_derived(records, Current.state) unless records.all? { |item| record?(item) }

        kept = []
        records.group_by(&:class).each do |record_class, group|
          policy = policy_for!(adapter, guard, record_class)
          return unpoliced(record_class) if policy.nil?

          kept.concat(in_scope(context, policy, adapter, record_class, group))
        end

        allow_records(kept, dominant_type(kept), kept.map { |record| identifier(record) })
      end

      # FR-006: a record outside the scope is never returned and never distinguished from
      # one that does not exist. The denial says nothing about the record.
      def scope_single_record(context, guard, record, adapter)
        policy = policy_for!(adapter, guard, record.class)
        return unpoliced(record.class) if policy.nil?

        return ScopeResult.deny(rule: Decision::OUT_OF_SCOPE_RECORD) if
          in_scope(context, policy, adapter, record.class, [record]).empty?

        allow_records(record, record.class.name, [identifier(record)])
      end

      # Anything that is not a record: a count, a sum, a string, a hash. Safe only if the
      # tool asked for a scoped relation rather than reaching for the model directly (R4).
      def scope_derived(result, state)
        unless state&.scoped_used?
          return ScopeResult.deny(
            rule: Decision::UNSCOPED_DERIVED_RESULT,
            detail: "the tool returned a #{result.class} without calling scoped(...), " \
                    "so what it was derived from cannot be established"
          )
        end

        ScopeResult.allow(records: result, derived: true,
                          record_count: state.scoped_source_count || 0)
      end

      # Two ways to answer "may this principal see this record?". For ActiveRecord, ask
      # the policy scope once and intersect identifiers — one query for the whole set.
      # For anything else there is no relation to narrow, so each record is authorized on
      # its own. The second path is what makes the core usable with no database at all.
      def in_scope(context, policy, adapter, record_class, records)
        visible = visible_ids_for(context, policy, adapter, record_class)
        if visible.nil?
          return records.select do |record|
            allowed?(adapter, context, policy, record)
          end
        end

        records.select { |record| visible.include?(identifier(record)) }
      end

      def visible_ids_for(context, policy, adapter, record_class)
        return nil unless active_record_class?(record_class)

        scoped = adapter.scope(
          principal: context.principal, policy: policy, relation: record_class.all
        )
        scoped.nil? ? nil : visible_ids(scoped)
      end

      def active_record_class?(record_class)
        defined?(::ActiveRecord::Base) &&
          record_class.is_a?(Class) &&
          record_class <= ::ActiveRecord::Base
      end

      def allowed?(adapter, context, policy, record)
        adapter.authorize(
          principal: context.principal, policy: policy, action: :show, record: record
        ).allowed?
      end

      def visible_ids(scoped)
        return nil unless relation?(scoped)

        scoped.pluck(:id).map(&:to_s)
      rescue StandardError
        nil
      end

      def policy_for!(adapter, guard, record_class)
        self.class.policy_for(adapter, guard, record_class)
      end

      def unpoliced(record_class)
        ScopeResult.deny(
          rule: Decision::UNKNOWN_RECORD_TYPE,
          detail: "no policy governs #{record_class}, so the result cannot be scoped"
        )
      end

      def allow_records(records, record_type, ids)
        limit = Reeve.config.max_recorded_ids
        total = ids.size

        ScopeResult.allow(
          records: records,
          record_type: record_type,
          record_ids: ids.first(limit),
          record_count: total,
          truncated: total > limit
        )
      end

      def record_ids(scoped)
        ids = visible_ids(scoped)
        return ids if ids

        Array(scoped).map { |record| identifier(record) }
      end

      def identifier(record)
        record.respond_to?(:id) ? record.id.to_s : record.to_s
      end

      def dominant_type(records)
        return nil if records.empty?

        records.group_by { |record| record.class.name }.max_by { |_, group| group.size }.first
      end

      def relation_class(relation)
        relation.respond_to?(:klass) ? relation.klass : relation.class
      end

      def relation?(value)
        defined?(::ActiveRecord::Relation) && value.is_a?(::ActiveRecord::Relation)
      end

      # Without ActiveRecord loaded there is no authoritative answer, so this asks the
      # only question that generalises: does it have an identity of its own?
      def record?(value)
        return true if defined?(::ActiveRecord::Base) && value.is_a?(::ActiveRecord::Base)
        # Hashes and arrays are shapes, not records. A Struct with an identity is a
        # record like any other — excluding it was arbitrary, and it is exactly what a
        # host without ActiveRecord reaches for.
        return false if value.is_a?(Hash) || value.is_a?(Array)

        value.respond_to?(:id) && value.class.respond_to?(:name) && !value.class.name.nil?
      end
    end
  end
end
