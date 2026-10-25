# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      module Retention
        # Checks the retention records (specs/005 FR-009): numbered 0 to n, each signed under a
        # key this verifier holds, each linked to the one before and record 0 to the genesis,
        # each boundary following on from the last. Leaves the boundary the walk starts after:
        # the last record of the unbroken run from record 0.
        #
        # A record whose key is not held cannot be checked; it still sets the boundary (the
        # rows it accounts for are gone either way) and makes the run unverifiable, never
        # intact and never broken. A record that fails ends the run: the walk starts at the one
        # before it, so the rows the failing record claims to account for are reported missing.
        class Check
          Summary = Struct.new(:purge, :through_sequence, :purged_at, :removed_chained,
                               :removed_pre_chain, :archived, :status, keyword_init: true) do
            def as_json(*)
              to_h.transform_keys(&:to_s).merge("status" => status.to_s)
            end
          end

          Result = Struct.new(:boundary, :summaries, keyword_init: true) do
            def as_json(*)
              { "through" => boundary&.through_sequence, "records" => summaries.map(&:as_json) }
            end
          end

          # `report` receives (kind, sequence, detail, invocation_id, key_id, retention:).
          def initialize(keyring:, report:)
            @keyring = keyring
            @report = report
          end

          def call(records, genesis_digest:)
            boundary = nil
            previous = nil
            summaries = records.each_with_index.map do |record, index|
              status = judge(record, index, previous,
                             previous ? previous.retention_digest : genesis_digest)
              boundary = record if boundary.equal?(previous) && status != :altered
              previous = record
              summary(record, status)
            end
            Result.new(boundary: boundary, summaries: summaries)
          end

          private

          attr_reader :keyring

          def judge(record, index, previous, link)
            if record.purge_number != index
              return altered(record,
                             "is numbered #{record.purge_number}, not #{index}")
            end
            return altered(record, "does not follow on from the purge before it") unless follows?(
              record, previous
            )

            secret = keyring.for(record.key_id)
            if secret.nil?
              @report.call(:unknown_key, nil, "signed by key #{record.key_id}", nil, record.key_id,
                           retention: record.purge_number)
              return :key_not_configured
            end
            return :verified if Digest.call(secret, record, previous_digest: link) ==
                                record.retention_digest

            altered(record, "does not match its digest; it was edited, or a record before it was")
          end

          def follows?(record, previous)
            through = previous ? previous.through_sequence : 0
            record.previous_through == through && record.through_sequence > through
          end

          def altered(record, detail)
            @report.call(:retention_altered, nil, detail, nil, nil, retention: record.purge_number)
            :altered
          end

          def summary(record, status)
            Summary.new(purge: record.purge_number, through_sequence: record.through_sequence,
                        purged_at: record.purged_at, removed_chained: record.removed_chained,
                        removed_pre_chain: record.removed_pre_chain, archived: record.archived,
                        status: status)
          end
        end
      end
    end
  end
end
