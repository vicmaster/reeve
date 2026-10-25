# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      module Retention
        # `bin/rails reeve:purge_ledger` (specs/005; constitution II, 1.1.0): removes the chain's
        # entries up to a checkpoint the anchor holds, and the rows written before the chain,
        # leaving a signed retention record so that what remains still verifies and the
        # removal reads as a purge, not as tampering.
        #
        # In this order, and nothing removed until the last step: refuse what cannot be backed;
        # pick the boundary; require the whole ledger to verify INTACT; stop here for a dry run;
        # write the archive; commit the record; delete in batches over the retention
        # connection. A purge stopped during the deletes leaves rows "awaiting purge", which a
        # rerun removes without a second record.
        class Purge
          BATCH_SIZE = 1_000

          DAY = 86_400

          EXACTLY_ONE = "give exactly one of through: (THROUGH=) and older_than: (OLDER_THAN=)"

          # `through` is a checkpoint's sequence; `older_than` a number of days. `archive` is a
          # path, or nil with `no_archive`.
          def initialize(entry_class:, through: nil, older_than: nil, archive: nil,
                         no_archive: false, confirm: false, batch_size: BATCH_SIZE)
            raise ArgumentError, EXACTLY_ONE if through.nil? == older_than.nil?

            @entry_class = entry_class
            @through = through
            @older_than = older_than
            @archive = archive
            @no_archive = no_archive
            @confirm = confirm
            @batch_size = batch_size
          end

          def call
            @preflight = Preflight.new(entry_class: entry_class, archive: @archive,
                                       no_archive: @no_archive)
            refusal = @preflight.refusal
            return refusal if refusal

            verification = Chain.verify(entry_class: entry_class, checkpoints: checkpoints)
            # INTACT first, a resume included: a forged record under a key nobody holds reads as
            # unverifiable, and resuming from it would delete rows on the forger's word.
            unless verification.intact?
              return PurgeResult.refused(:not_intact, detail: verification.to_s.lines.first.chomp)
            end
            return resume(verification) if verification.awaiting_purge.positive?

            purge(verification)
          end

          private

          attr_reader :entry_class

          def keyring = @preflight.keyring

          def guard = @preflight.guard

          def checkpoints
            (@checkpoints ||= Checkpoint.read_all(Reeve.config.ledger_anchor.checkpoints))
          end

          # A resumed purge already wrote its archive; only a new one needs a path for it.
          def purge(verification)
            refusal = @preflight.archive_refusal
            return refusal if refusal

            current = verification.retention&.boundary
            boundary = Boundary.new(entry_class, checkpoints, verification)
            chosen = @through ? boundary.at(@through) : boundary.older_than(cutoff)
            return chosen unless chosen.is_a?(Checkpoint)

            plan = Plan.new(entry_class, current, chosen)
            unless @confirm
              return PurgeResult.from(plan, :dry_run, archive: @archive,
                                                      warnings: guard.warnings)
            end

            commit(plan)
          end

          def cutoff = Time.now - (@older_than * DAY)

          def commit(plan)
            sha256 = @no_archive ? nil : Archive.write(@archive, plan, entry_class: entry_class)
            number = insert_record(plan, sha256)
            delete_through(plan.through)
            PurgeResult.from(plan, :purged, archive: @archive, archive_sha256: sha256,
                                            purge: number,
                                            warnings: guard.warnings)
          rescue ActiveRecord::RecordNotUnique
            PurgeResult.refused(:purge_running)
          end

          # The record names the boundary checkpoint, what the purge removes, and the archive,
          # signed and linked to the record before it (data-model).
          def insert_record(plan, sha256)
            values = plan.record_values(sha256, keyring.signing_id)
            values["retention_digest"] =
              Digest.call(keyring.signing_secret, values, previous_digest: plan.previous_digest)
            guard.pool.with_connection { |connection| insert(connection, values) }
            values["purge_number"]
          end

          def insert(connection, values)
            quoted = values.values.map { |value| connection.quote(value) }
            columns = values.keys.join(", ")
            connection.insert("INSERT INTO #{RetentionRecord.table_name} (#{columns}) " \
                              "VALUES (#{quoted.join(', ')})")
          end

          # A purge whose record is written but whose rows are not all gone: finish it.
          def resume(verification)
            boundary = verification.retention.boundary
            removed = delete_through(boundary.through_sequence)
            PurgeResult.resumed(boundary, removed, warnings: guard.warnings)
          end

          def delete_through(through)
            removed = 0
            loop do
              count = delete_batch(through)
              removed += count
              break if count < @batch_size
            end
            removed
          end

          # One batch, in its own transaction: rows chained at or below the boundary, and rows
          # written before the chain. Unchained contract-3+ rows are left (spec Clarifications).
          def delete_batch(through)
            guard.pool.with_connection do |connection|
              ids = connection.select_values(doomed_ids(through)).map { |id| Integer(id) }
              next 0 if ids.empty?

              connection.delete("DELETE FROM #{entry_class.table_name} " \
                                "WHERE id IN (#{ids.join(', ')})")
            end
          end

          def doomed_ids(through)
            "SELECT id FROM #{entry_class.table_name} WHERE (chain_sequence IS NOT NULL AND " \
              "chain_sequence <= #{Integer(through)}) OR contract_version < 3 ORDER BY id " \
              "LIMIT #{Integer(@batch_size)}"
          end
        end
      end
    end
  end
end
