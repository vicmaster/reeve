# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      module Retention
        # Which checkpoint a purge stops at (specs/005 FR-002): one the anchor holds, that
        # verification checked, above the current boundary.
        class Boundary
          def initialize(entry_class, checkpoints, verification)
            @entry_class = entry_class
            @current = current_through(verification)
            checked = checkpoints.zip(verification.checkpoints)
                                 .select { |_, found| found.status == :checked }.map(&:first)
            @candidates = checked.select { |checkpoint| checkpoint.head_sequence > @current }
                                 .uniq(&:head_sequence).sort_by(&:head_sequence)
          end

          # The checkpoint at `sequence`, or the PurgeResult that says why there is none.
          def at(sequence)
            return PurgeResult.nothing(:at_or_below, current: @current) if sequence <= @current

            found = @candidates.find { |checkpoint| checkpoint.head_sequence == sequence }
            found || PurgeResult.refused(:no_checkpoint, detail: nearest(sequence))
          end

          # The highest checkpoint whose entry occurred before `cutoff`.
          def older_than(cutoff)
            times = occurred_at(@candidates.map(&:head_sequence))
            older = @candidates.select { |checkpoint| times[checkpoint.head_sequence]&.<(cutoff) }
            older.last || PurgeResult.nothing(:none_older, current: @current)
          end

          private

          def current_through(verification)
            boundary = verification.retention&.boundary
            boundary ? boundary.through_sequence : 0
          end

          def nearest(sequence)
            below = @candidates.reverse.find { |checkpoint| checkpoint.head_sequence < sequence }
            above = @candidates.find { |checkpoint| checkpoint.head_sequence > sequence }
            [below, above].map do |checkpoint|
              checkpoint ? "##{Report.number(checkpoint.head_sequence)}" : "none"
            end
          end

          def occurred_at(sequences)
            @entry_class.where(chain_sequence: sequences).pluck(:chain_sequence, :occurred_at).to_h
          end
        end

        # What one purge removes and records (data-model "reeve_audit_retentions").
        class Plan
          attr_reader :checkpoint, :from, :through, :previous_through, :previous_digest, :purge,
                      :removed_chained, :removed_pre_chain, :start

          # `current` is the latest retention record, or nil before the first purge.
          def initialize(entry_class, current, checkpoint)
            @checkpoint = checkpoint
            @through = checkpoint.head_sequence
            current ? follow(current) : first
            @from = @previous_through + 1
            @removed_chained = entry_class.where(chain_sequence: from..through).count
            @removed_pre_chain = entry_class.where("contract_version < 3").count
          end

          def record_values(archive_sha256, key_id)
            {
              "purge_number" => purge, "through_sequence" => through,
              "through_digest" => checkpoint.head_digest,
              "previous_through" => previous_through, "removed_chained" => removed_chained,
              "removed_pre_chain" => removed_pre_chain, "archived" => !archive_sha256.nil?,
              "archive_sha256" => archive_sha256, "purged_at" => Time.now.utc.floor(6),
              "key_id" => key_id
            }
          end

          private

          def first
            @previous_through = 0
            @purge = 0
            @previous_digest = ChainRecord.ledger.genesis_digest
            @start = nil
          end

          def follow(current)
            @previous_through = current.through_sequence
            @purge = current.purge_number + 1
            @previous_digest = current.retention_digest
            @start = { "through_sequence" => current.through_sequence,
                       "through_digest" => current.through_digest }
          end
        end
      end
    end
  end
end
