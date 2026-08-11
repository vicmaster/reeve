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
      #
      # "Exists" means *is a model*, not merely "is a defined constant". Asking
      # `Object.const_defined?` alone handed `DataPolicy`, `SetPolicy`, `FilePolicy` and
      # every anonymous policy class (whose name falls back to "Class") to a
      # convention-named policy instead, because `Data`, `Set`, `File` and `Class` are all
      # defined in Ruby — the same silent substitution this method exists to prevent.
      def self.declared_for_other_type?(declaration, record_class)
        named = declaration.policy_name.to_s.sub(/Policy\z/, "")
        return false if named.empty? || named == base_class_name(record_class)

        target = resolve_constant(named)
        return false unless model_like?(target)

        target != base_class(record_class)
      end

      def self.resolve_constant(name)
        Object.const_defined?(name) ? Object.const_get(name) : nil
      rescue NameError
        nil
      end

      # A model, not just any class: something records are actually fetched from.
      def self.model_like?(target)
        return false unless target.is_a?(Class)
        return true if defined?(::ActiveRecord::Base) && target <= ::ActiveRecord::Base

        target.respond_to?(:all)
      end

      # Single-table inheritance: `TextComment` is governed by `CommentPolicy`, because
      # the policy is written for the table, not for each subclass. Comparing subclasses
      # directly denied every STI result with `unknown_record_type`.
      def self.base_class(record_class)
        return record_class unless record_class.is_a?(Class)
        return record_class unless record_class.respond_to?(:base_class)

        record_class.base_class
      rescue StandardError
        record_class
      end

      # `InvoicePolicy` is named for `Invoice`.
      def self.policy_named_for?(policy, record_class)
        name = policy.respond_to?(:name) && policy.name ? policy.name : policy.class.name
        name.to_s.sub(/Policy\z/, "") == base_class_name(record_class)
      end

      def self.base_class_name(record_class)
        base_class(record_class).name.to_s
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

      # An array can hold records, non-records, or both. Each part is judged on its own
      # terms: records are scoped, and anything else is a derived value, allowed only if
      # the tool asked for a scoped relation.
      #
      # This used to hand the whole array to the derived path the moment one element was
      # not a record, so a tool returning `[invoice, invoice, { total: 2 }]` had its
      # invoices returned entirely unscoped as soon as it had called `scoped(...)`
      # anywhere in its body — with no identifiers in the ledger to show for it.
      def scope_array(context, guard, items, adapter)
        return ScopeResult.allow(records: [], record_count: 0) if items.empty?

        records, others = items.partition { |item| record?(item) }
        return scope_derived(items, Current.state) if records.empty?
        return unscoped_derived(others.first) unless derivation_established?(others)

        kept = keep_in_scope(context, guard, records, adapter)
        kept.is_a?(ScopeResult) ? kept : allow_survivors(items, kept)
      end

      def derivation_established?(others)
        others.empty? || Current.state&.scoped_used? || false
      end

      # Keeps the tool's own ordering: the caller asked for a list, not a set.
      def allow_survivors(items, kept)
        surviving = items.select { |item| record?(item) ? kept.include?(item) : true }

        allow_records(surviving, dominant_type(kept), kept.map { |record| identifier(record) })
      end

      # The records the principal may see, or a denial when some type has no policy.
      def keep_in_scope(context, guard, records, adapter)
        kept = []
        groups = records.group_by { |record| self.class.base_class(record.class) }

        groups.each do |record_class, group|
          policy = policy_for!(adapter, guard, record_class)
          return unpoliced(record_class) if policy.nil?
          return ungoverned(record_class) unless governed?(record_class, policy, adapter)

          kept.concat(in_scope(context, policy, adapter, record_class, group))
        end

        kept
      end

      # A type with no relation cannot be checked against a scope, only against the
      # policy's own `authorize` — and a policy whose real protection lives in `scope`
      # commonly answers `true` to everything else. So a scope-less type is trusted only
      # when something ties it to the policy: a policy named for it, or a `scoped(...)`
      # call establishing where the values came from.
      #
      # Without this, a tool returning `Invoice.all.map { Row.new(...) }` had every row
      # allowed by a catch-all `authorize`, which is what a Struct used to be protected
      # from by being classed as a derived value.
      def governed?(record_class, policy, adapter)
        return true if relation_source?(record_class)
        return true if Current.state&.scoped_used?
        return true if self.class.policy_named_for?(policy, record_class)

        !adapter.policy_for(self.class.base_class(record_class)).nil?
      end

      def ungoverned(record_class)
        ScopeResult.deny(
          rule: Decision::UNKNOWN_RECORD_TYPE,
          detail: "#{record_class} has no relation to scope and no policy named for it, " \
                  "so what the principal may see cannot be established — derive it " \
                  "through scoped(...) or give the type its own policy"
        )
      end

      def unscoped_derived(example)
        ScopeResult.deny(
          rule: Decision::UNSCOPED_DERIVED_RESULT,
          detail: "the tool returned a #{example.class} alongside records without calling " \
                  "scoped(...), so what it was derived from cannot be established"
        )
      end

      # FR-006: a record outside the scope is never returned and never distinguished from
      # one that does not exist. The denial says nothing about the record.
      def scope_single_record(context, guard, record, adapter)
        policy = policy_for!(adapter, guard, record.class)
        return unpoliced(record.class) if policy.nil?
        return ungoverned(record.class) unless governed?(record.class, policy, adapter)

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

      # "May this principal see these records?" has two honest answers and one dishonest
      # one. For a model backed by a relation, ask the policy scope which of *these*
      # identifiers it admits. For a type with no relation to narrow, authorize each
      # record on its own — that is what makes the core usable with no database.
      #
      # The dishonest answer, which this used to give: if the scope could not be read,
      # fall back to a per-record `authorize` and keep whatever it permits. A policy whose
      # `Scope#resolve` ends in `.to_a`, or a model whose primary key is not `id`, would
      # silently downgrade set-based scoping to a `show?` check that is commonly
      # `user.present?` — every record kept, recorded as properly scoped. A scope we
      # cannot read is now a denial (Constitution I: unclear means no).
      def in_scope(context, policy, adapter, record_class, records)
        unless relation_source?(record_class)
          return authorize_each(adapter, context, policy,
                                records)
        end

        visible = visible_ids_among(context, policy, adapter, record_class, records)
        records.select { |record| visible.include?(identifier(record)) }
      end

      def authorize_each(adapter, context, policy, records)
        records.select { |record| allowed?(adapter, context, policy, record) }
      end

      # Bounded by the records actually being checked, never by the table: a single-record
      # lookup against a scope of two million rows must not pluck two million ids.
      def visible_ids_among(context, policy, adapter, record_class, records)
        scoped = adapter.scope(
          principal: context.principal, policy: policy, relation: record_class.all
        )
        raise Error, "#{policy} returned no scope for #{record_class}" if scoped.nil?

        ids = records.map { |record| record_id(record) }.compact
        return [] if ids.empty?

        narrowed = scoped.respond_to?(:where) ? scoped.where(id: ids) : scoped
        identifiers_of(narrowed)
      end

      # Raises rather than returning nil: the caller cannot tell "nothing is visible" from
      # "I could not find out", and only one of those is safe to act on.
      def identifiers_of(scoped)
        return scoped.pluck(:id).map(&:to_s) if scoped.respond_to?(:pluck)

        Array(scoped).map { |record| identifier(record) }
      rescue StandardError => e
        raise Error,
              "could not read the policy scope to establish record visibility " \
              "(#{e.class}: #{e.message})"
      end

      def relation_source?(record_class)
        active_record_class?(record_class)
      end

      def active_record_class?(record_class)
        defined?(::ActiveRecord::Base) &&
          record_class.is_a?(Class) &&
          record_class <= ::ActiveRecord::Base
      end

      # The action the guard declared, not a hardcoded one: a host whose policies speak
      # `:read` would otherwise fall through to a catch-all `else` and permit everything.
      def allowed?(adapter, context, policy, record)
        adapter.authorize(
          principal: context.principal, policy: policy, action: current_action, record: record
        ).allowed?
      end

      def current_action
        Current.state&.declaration&.action || Reeve.config.default_action
      end

      def visible_ids(scoped)
        identifiers_of(scoped)
      end

      def policy_for!(adapter, guard, record_class)
        self.class.policy_for(adapter, guard, self.class.base_class(record_class))
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

      def record_id(record)
        record.respond_to?(:id) ? record.id : nil
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
