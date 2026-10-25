# frozen_string_literal: true

require "time"

module Reeve
  module Audit
    class Chain
      # A Verification in words (contracts/ledger-chain.md "Output").
      #
      # Every summary line carries its own coverage. A reader who copies only the first line
      # into a ticket still copies how much of the ledger the word in it covers — "INTACT"
      # never travels without "sequences 1–n" and the count of what was not covered.
      #
      # Unknown-key breaks are summarized, not listed: there is one per row a missing key
      # signed, and the summary already names the key and the count.
      class Report
        LABEL_WIDTH = 14
        KIND_WIDTH = 17
        PREFIX = "reeve ledger:"
        NOTHING_AFTER_PURGE = "no entries after the purge to verify"

        def self.number(value)
          digits = value.abs.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
          value.negative? ? "-#{digits}" : digits
        end

        def initialize(verification)
          @v = verification
        end

        def to_s(limit:)
          listed = @v.breaks.reject { |found| found.kind == :unknown_key }
          epochs = EpochLines.new(@v).to_a
          return [summary, *epochs].join("\n") if listed.empty?

          lines = listed.first(limit).map { |found| line_for(found) }
          [summary, totals, *epochs, *lines, more(listed, limit)].compact.join("\n")
        end

        private

        def summary
          case @v.status
          when :intact then intact
          when :broken then broken
          when :no_chain then no_chain
          else @v.reason == :no_key ? no_key : unverifiable
          end
        end

        def intact
          if @v.walked_from
            return "#{PREFIX} INTACT — #{anchor_text.walked_from}; #{uncovered}; #{anchor_text}"
          end

          walked = @v.covered ? "sequences #{range(@v.covered)} verified" : NOTHING_AFTER_PURGE
          "#{PREFIX} INTACT — #{walked} (head at start: #{number(@v.head_at_start)}); " \
            "#{uncovered}; #{anchor_text}"
        end

        def broken
          count = @v.breaks.size
          breaks = "#{number(count)} break#{'s' unless count == 1}"
          if anchor_text.emptied?
            return "#{PREFIX} BROKEN — #{breaks} in the ledger; #{anchor_text.emptied}"
          end

          where = @v.covered ? "in sequences #{range(@v.covered)}" : "in the ledger"
          "#{PREFIX} BROKEN — #{breaks} #{where}; #{uncovered}; #{anchor_text}"
        end

        def anchor_text = (@anchor_text ||= AnchorText.new(@v))

        def no_chain
          "#{PREFIX} NO CHAIN — #{number(@v.uncovered_now + @v.unchained_now)} entries, " \
            "none chained; nothing was verified"
        end

        def no_key = "#{PREFIX} UNVERIFIABLE — no ledger key configured; nothing was verified"

        # The purge clause leads here too (FR-011), but the uncovered count stays as 0.6.0 wrote it.
        def unverifiable
          "#{PREFIX} UNVERIFIABLE — #{UnverifiableText.new(@v)}; #{RetentionText.new(@v).clause}" \
            "#{number(@v.uncovered_now)} earlier entries not covered; #{anchor_text}"
        end

        # After a purge, what it removed comes first (specs/005 FR-011): no line says what was
        # verified without saying what was purged before it.
        def uncovered
          retention = RetentionText.new(@v)
          parts = [retention.clause, "#{number(@v.uncovered_now)} earlier entries not covered"]
          at_genesis = @v.uncovered_at_genesis
          if at_genesis
            parts << " (#{number(at_genesis)} when the chain started#{retention.pre_chain})"
          end
          unless @v.unchained_at_genesis.to_i.zero?
            parts << "; #{number(@v.unchained_at_genesis)} unchained entries from before the " \
                     "chain started, not covered"
          end
          parts.join
        end

        def totals = "  totals: #{@v.totals.map { |kind, count| "#{kind} #{count}" }.join(', ')}"

        def more(listed, limit)
          remaining = listed.size - limit
          return nil unless limit.positive? && remaining.positive?

          "  … and #{number(remaining)} more (the totals above are complete)"
        end

        # One space at least between columns, so a label or kind longer than its column
        # (`checkpoint #48,000`, `checkpoint_not_reached`) never runs into the next.
        def line_for(found)
          label = label(found).ljust(LABEL_WIDTH - 1)
          kind = found.kind.to_s.ljust(KIND_WIDTH - 1)
          "  #{label} #{kind} #{found.detail}".rstrip
        end

        def label(found)
          return "invocation #{found.invocation_id}" if found.invocation_id
          return "checkpoint ##{number(found.checkpoint)}" if found.checkpoint
          return "retention #{found.retention}" if found.retention
          return "epoch #{found.epoch}" if found.sequence.nil? && found.epoch

          position(found.sequence)
        end

        def position(sequence)
          return "—" if sequence.nil?
          return "##{range(sequence)}" if sequence.is_a?(Range)

          sequence.zero? ? "genesis" : "##{number(sequence)}"
        end

        def range(value)
          return "—" if value.nil?

          "#{number(value.first)}–#{number(value.last)}"
        end

        def number(value)
          self.class.number(value.to_i)
        end
      end

      # What an unverifiable run could not check, and what it did (the UNVERIFIABLE line). Rows
      # signed by a key that is not configured are counted; a checkpoint whose key is missing is
      # named apart from them and is not one (specs/004).
      class UnverifiableText
        def initialize(verification)
          @v = verification
          unknown = verification.breaks.select { |found| found.kind == :unknown_key }
          @checkpoints, unknown = unknown.partition(&:checkpoint)
          @records, @signed = unknown.partition(&:retention)
        end

        def to_s
          rows = @signed.count { |found| entry?(found.sequence) }
          checked = @v.covered ? @v.covered.size - rows : 0
          "#{unchecked(rows)}; the other #{Report.number(checked)} in #{range} show no breaks, " \
            "which is not a pass"
        end

        private

        def unchecked(rows)
          parts = []
          parts << "#{Report.number(rows)} entries signed by #{missing(@signed)}" if @signed.any?
          parts << other("checkpoint", @checkpoints) if @checkpoints.any?
          parts << other("retention record", @records) if @records.any?
          parts.join("; ")
        end

        # Not entries, so named apart and not counted as rows.
        def other(noun, found)
          count = found.size
          "#{Report.number(count)} #{noun}#{'s' unless count == 1} signed by #{missing(found)}"
        end

        # The genesis is position 0 and is not an entry.
        def entry?(sequence)
          sequence.is_a?(Integer) && sequence.positive?
        end

        def missing(unknown)
          keys = unknown.map(&:key_id).compact.uniq
          named = keys.one? ? "key #{keys.first}, which is" : "keys #{keys.join(', ')}, which are"
          "#{named} not configured"
        end

        def range
          return "—" if @v.covered.nil?

          "#{Report.number(@v.covered.first)}–#{Report.number(@v.covered.last)}"
        end
      end

      # What the ledger's purges removed, in words (specs/005 FR-011): the clause that leads the
      # coverage on every walked summary line, and the pre-chain rows a purge removed.
      class RetentionText
        def initialize(verification)
          @retention = verification.retention
          @awaiting = verification.awaiting_purge.to_i
        end

        def clause
          boundary = @retention&.boundary
          return "" if boundary.nil?

          text = "1–#{Report.number(boundary.through_sequence)} purged (retention record " \
                 "#{boundary.purge_number}, #{boundary.purged_at.utc.strftime('%Y-%m-%d')}); "
          text += "#{Report.number(@awaiting)} entries awaiting purge; " if @awaiting.positive?
          text
        end

        def pre_chain
          purged = if @retention
                     @retention.summaries.reject { |found| found.status == :altered }
                               .sum(&:removed_pre_chain)
                   else
                     0
                   end
          purged.positive? ? ", #{Report.number(purged)} purged" : ""
        end
      end

      # What a run was anchored by, in words (specs/004 FR-014, FR-015): the clause every walked
      # summary line ends with, and the wording for a walk from a checkpoint and for an emptied
      # ledger that checkpoints saw.
      class AnchorText
        # A checkpoint's time for people: "2026-10-25 14:00 UTC". A time that does not parse is
        # shown as written; verification never depends on it.
        def self.made_on(made_at)
          Time.iso8601(made_at).utc.strftime("%Y-%m-%d %H:%M UTC")
        rescue ArgumentError
          made_at
        end

        def initialize(verification)
          @v = verification
        end

        # The highest checkpoint that checked, and how many entries it does not cover.
        def to_s
          anchor = @v.anchored_at
          return "not anchored" if anchor.nil?

          after = @v.beyond_anchor.to_i
          "anchored at ##{number(anchor.head_sequence)} (checkpoint #{made_on(anchor)}), " \
            "#{number(after)} #{after == 1 ? 'entry' : 'entries'} after it"
        end

        def walked_from
          start = @v.walked_from
          from = "checkpoint ##{number(start.head_sequence)} (#{made_on(start)})"
          walked = if @v.covered
                     "sequences #{range} verified from #{from}"
                   else
                     "no entries after #{from}"
                   end
          "#{walked}; #{number(start.head_sequence)} earlier chained entries not walked by " \
            "this run"
        end

        # No walk, and checkpoints that saw a chain.
        def emptied?
          @v.head_at_start.nil? && @v.checkpoints.any?
        end

        def emptied
          count = @v.checkpoints.size
          "the ledger has no chain, but #{number(count)} checkpoint#{'s' unless count == 1} " \
            "name#{'s' if count == 1} one"
        end

        private

        def number(value)
          Report.number(value)
        end

        def made_on(checkpoint)
          AnchorText.made_on(checkpoint.made_at)
        end

        def range
          "#{number(@v.covered.first)}–#{number(@v.covered.last)}"
        end
      end

      # The key epochs, one line each (specs/003 FR-013), shown once they say something the
      # summary does not: more than one, one that is not verified, or rows chained before the
      # first. A ledger with one verified epoch and nothing before it reads as 0.6.0's did.
      class EpochLines
        STATUS_WORDS = {
          verified: "verified", key_not_configured: "key not configured", altered: "altered"
        }.freeze

        def initialize(verification)
          @epochs = verification.epochs
          @before = verification.before_first_epoch.to_i
        end

        def to_a
          return [] unless shown?

          lines = @epochs.map { |epoch| line(epoch) }
          return lines unless @before.positive?

          ["  before epoch 0  #{entries(@before)} chained before key epochs began", *lines]
        end

        private

        def shown?
          return false if @epochs.empty?

          @epochs.size > 1 || @epochs.first.status != :verified || @before.positive?
        end

        def line(epoch)
          "  epoch #{epoch.epoch}  key #{epoch.key_id}  " \
            "from sequence #{Report.number(epoch.first_sequence)}  " \
            "#{entries(epoch.entry_count)}  #{STATUS_WORDS.fetch(epoch.status)}"
        end

        def entries(count)
          "#{Report.number(count)} #{count == 1 ? 'entry' : 'entries'}"
        end
      end
    end
  end
end
