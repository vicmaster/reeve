# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # The verifier's checkpoints (specs/004): what it checks the ledger against, and the one,
      # if any, it walks from instead of the genesis.
      #
      # Checkpoints come from outside the database (FR-010). With none, the verifier is exactly
      # 0.7.0's and its report says the run was not anchored.
      class Anchoring
        attr_reader :checkpoints, :from

        # `from` is :latest, a Checkpoint, or nil to walk from the genesis (Checkpoint.start).
        def initialize(entry_class:, keyring:, checkpoints:, from: nil)
          @entry_class = entry_class
          @keyring = keyring
          @checkpoints = checkpoints
          @from = Checkpoint.start(from, checkpoints)
        end

        def any?
          checkpoints.any?
        end

        # The latest retention record that holds (specs/005), or nil: the walk never starts
        # below it, and a `from` at or below it is moot.
        attr_reader :floor

        def floor=(record)
          @floor = record
          @from = nil if record && from && from.head_sequence <= record.through_sequence
        end

        # Where the walk starts, and the digest its first row links to.
        def start
          return from.head_sequence if from
          return floor.through_sequence if floor

          0
        end

        def link(record)
          return from.head_digest if from
          return floor.through_digest if floor

          record&.genesis_digest
        end

        # Every checkpoint, after the walk, against the head read after it. The checked
        # checkpoint with the highest sequence anchors the run (data-model).
        def check(record, head, epoch_records, report:)
          results = check_with(report).call(checkpoints, record: record, head: head,
                                                         epochs: epoch_records, floor: floor)
          anchor = results.select { |found| found.status == :checked }.max_by(&:head_sequence)
          beyond = anchor && record && [record.head_sequence - anchor.head_sequence, 0].max
          { checkpoints: results, anchored_at: anchor, beyond_anchor: beyond }
        end

        # A ledger with no chain, which every checkpoint saw reach an entry: emptied, not never
        # chained (FR-013).
        def emptied(record, report:)
          check_with(report).call(checkpoints, record: record, head: record, epochs: [],
                                               chained: false)
        end

        # The starting checkpoint, checked alone before the walk relies on it (FR-015). Returns
        # its results when it does not hold, reporting its breaks; nil when it holds, so its
        # breaks are left to the full check after the walk.
        def failed_start(record, epoch_records, report:)
          return nil if from.nil?

          found = []
          collect = ->(*args, **options) { found << [args, options] }
          results = check_with(collect).call([from], record: record, head: record,
                                                     epochs: epoch_records, floor: floor)
          return nil if results.first.status == :checked

          found.each { |args, options| report.call(*args, **options) }
          results
        end

        private

        def check_with(report)
          CheckpointCheck.new(entry_class: @entry_class, keyring: @keyring, report: report)
        end
      end
    end
  end
end
