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

      def self.policy_for(adapter, declaration, record_class)
        return declaration.policy if record_class.nil? || declared_type?(declaration, record_class)

        adapter.policy_for(record_class) || nil
      end

      # A declared policy governs the type it is named for. `InvoicePolicy` governs
      # `Invoice`; anything else has to be resolvable independently or the call denies.
      def self.declared_type?(declaration, record_class)
        declaration.policy_name.to_s.sub(/Policy\z/, "") == record_class.name.to_s
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

      def in_scope(context, policy, adapter, record_class, records)
        scoped = adapter.scope(
          principal: context.principal, policy: policy, relation: relation_for(record_class)
        )
        return records.select { |record| allowed?(adapter, context, policy, record) } if scoped.nil?

        visible = visible_ids(scoped)
        if visible.nil?
          return records.select do |record|
            allowed?(adapter, context, policy, record)
          end
        end

        records.select { |record| visible.include?(identifier(record)) }
      end

      def allowed?(adapter, context, policy, record)
        adapter.authorize(
          principal: context.principal, policy: policy, action: :show, record: record
        ).allowed?
      end

      def visible_ids(scoped)
        return nil unless scoped.respond_to?(:pluck)

        scoped.pluck(:id).map(&:to_s)
      rescue StandardError
        nil
      end

      def relation_for(record_class)
        record_class.respond_to?(:all) ? record_class.all : []
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
        return false if value.is_a?(Hash) || value.is_a?(Array) || value.is_a?(Struct)

        value.respond_to?(:id) && value.class.respond_to?(:name) && !value.class.name.nil?
      end
    end
  end
end
