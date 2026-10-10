# frozen_string_literal: true

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

        def self.number(value)
          digits = value.abs.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
          value.negative? ? "-#{digits}" : digits
        end

        def initialize(verification)
          @v = verification
        end

        def to_s(limit:)
          listed = @v.breaks.reject { |found| found.kind == :unknown_key }
          return summary if listed.empty?

          lines = listed.first(limit).map { |found| line_for(found) }
          [summary, totals, *lines, more(listed, limit)].compact.join("\n")
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
          "#{PREFIX} INTACT — sequences #{range(@v.covered)} verified " \
            "(head at start: #{number(@v.head_at_start)}); #{uncovered}"
        end

        def broken
          count = @v.breaks.size
          where = @v.covered ? "in sequences #{range(@v.covered)}" : "in the ledger"
          "#{PREFIX} BROKEN — #{number(count)} break#{'s' unless count == 1} #{where}; #{uncovered}"
        end

        def no_chain
          "#{PREFIX} NO CHAIN — #{number(@v.uncovered_now + @v.unchained_now)} entries, " \
            "none chained; nothing was verified"
        end

        def no_key
          "#{PREFIX} UNVERIFIABLE — no ledger key configured; nothing was verified"
        end

        def unverifiable
          unknown = @v.breaks.select { |found| found.kind == :unknown_key }
          rows = unknown.count { |found| entry_position?(found.sequence) }
          checked = @v.covered ? @v.covered.size - rows : 0
          "#{PREFIX} UNVERIFIABLE — #{number(rows)} entries signed by #{missing_keys(unknown)} " \
            "not configured; the other #{number(checked)} in #{range(@v.covered)} show no " \
            "breaks, which is not a pass; #{number(@v.uncovered_now)} earlier entries not covered"
        end

        # The genesis is position 0 and is not an entry.
        def entry_position?(sequence)
          sequence.is_a?(Integer) && sequence.positive?
        end

        def missing_keys(unknown)
          keys = unknown.map(&:key_id).compact.uniq
          keys.one? ? "key #{keys.first}, which is" : "keys #{keys.join(', ')}, which are"
        end

        def uncovered
          parts = ["#{number(@v.uncovered_now)} earlier entries not covered"]
          at_genesis = @v.uncovered_at_genesis
          parts << " (#{number(at_genesis)} when the chain started)" if at_genesis
          unless @v.unchained_at_genesis.to_i.zero?
            parts << "; #{number(@v.unchained_at_genesis)} unchained entries from before the " \
                     "chain started, not covered"
          end
          parts.join
        end

        def totals
          "  totals: #{@v.totals.map { |kind, count| "#{kind} #{count}" }.join(', ')}"
        end

        def more(listed, limit)
          remaining = listed.size - limit
          return nil unless limit.positive? && remaining.positive?

          "  … and #{number(remaining)} more (the totals above are complete)"
        end

        def line_for(found)
          kind = found.kind.to_s.ljust(KIND_WIDTH)
          "  #{label(found).ljust(LABEL_WIDTH)}#{kind}#{found.detail}".rstrip
        end

        def label(found)
          sequence = found.sequence
          return "invocation #{found.invocation_id}" if found.invocation_id
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
    end
  end
end
