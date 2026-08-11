# frozen_string_literal: true

module Reeve
  # What the scoper hands back to the envelope: the decision, the value the caller may
  # actually receive, and the identifiers the ledger records.
  #
  # The envelope never reads records out of the tool's own return value — only out of
  # this object — which is how invariant 3 ("no path returns records without scoping")
  # holds by construction rather than by review.
  class ScopeResult
    SCOPED = "scoped"

    attr_reader :decision, :records, :record_type, :record_ids, :record_count

    def self.allow(records:, record_type: nil, record_ids: nil, record_count: nil,
                   truncated: false, derived: false, rule: SCOPED)
      new(
        decision: Decision.allow(rule: rule),
        records: records,
        record_type: record_type,
        record_ids: record_ids,
        record_count: record_count,
        truncated: truncated,
        derived: derived
      )
    end

    def self.deny(rule:, detail: nil)
      new(decision: Decision.deny(rule: rule, detail: detail), records: nil)
    end

    # For a result nothing narrowed — the `:allow_with_warning` path. It still has to say
    # what came back: an entry reading `record_count: 0` for a call that returned the whole
    # table is not merely incomplete but false, and this is the one path on which
    # everything came back.
    def self.unscoped(records:, rule:)
      identifiers = identifiers_in(records)
      limit = Reeve.config.max_recorded_ids

      new(
        decision: Decision.allow(rule: rule),
        records: records,
        record_type: type_of(records),
        record_ids: identifiers.first(limit),
        record_count: identifiers.size,
        truncated: identifiers.size > limit
      )
    end

    def self.identifiers_in(records)
      Array(records).filter_map { |record| record.id.to_s if record.respond_to?(:id) }
    rescue StandardError
      []
    end

    def self.type_of(records)
      first = Array(records).first
      first.respond_to?(:id) ? first.class.name : nil
    rescue StandardError
      nil
    end

    def initialize(decision:, records: nil, record_type: nil, record_ids: nil,
                   record_count: nil, truncated: false, derived: false)
      @decision    = decision
      @derived     = derived ? true : false
      @records     = records
      @record_type = @derived ? nil : record_type
      @record_ids  = (@derived ? [] : Array(record_ids)).map(&:to_s).freeze
      @record_count = record_count || @record_ids.size
      @truncated = truncated ? true : false
      freeze
    end

    def allowed?
      decision.allowed?
    end

    def denied?
      decision.denied?
    end

    def derived?
      @derived
    end

    def truncated?
      @truncated
    end

    # The ledger-facing half of the entry; Context#to_h supplies the other half.
    def to_h
      {
        outcome: decision.outcome.to_s,
        rule: decision.rule,
        record_type: record_type,
        record_ids: record_ids,
        record_count: record_count,
        truncated: truncated?,
        derived: derived?
      }
    end
  end
end
