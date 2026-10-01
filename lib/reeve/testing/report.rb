# frozen_string_literal: true

module Reeve
  module Testing
    # The aggregate of one compliance run (FR-018).
    #
    # +to_s+ is written to be the whole output of a failing CI step: a one-line verdict
    # followed by every failure in full. A report that has to be cross-referenced with
    # something else is a report nobody reads at 3am.
    class Report
      attr_reader :results

      def initialize(results)
        @results = results.freeze
        freeze
      end

      # Nothing failed. A skip is not a failure — and it is printed, so it is not
      # mistaken for a pass either.
      def passed?
        failures.empty?
      end

      def failed?
        !passed?
      end

      # Every result was a skip: the run established nothing either way. The front-ends
      # report this as a skipped test rather than a green one.
      def skipped?
        !results.empty? && results.all?(&:skipped?)
      end

      def failures
        results.select(&:failed?)
      end

      def passes
        results.select(&:passed?)
      end

      def skips
        results.select(&:skipped?)
      end

      def size
        results.size
      end

      def to_s
        [summary, *failures.map { |result| detail("FAIL", result) },
         *skips.map { |result| detail("SKIP", result) }].join("\n")
      end

      def inspect
        "#<Reeve::Testing::Report #{summary}>"
      end

      private

      def summary
        line = "reeve compliance: #{size} #{size == 1 ? 'check' : 'checks'}, " \
               "#{passes.size} passed, #{failures.size} failed"
        skips.empty? ? line : "#{line}, #{skips.size} skipped"
      end

      # Every line of a multi-line message indented, so it reads as one block under its
      # heading rather than as stray lines of the report.
      def detail(heading, result)
        "\n#{heading} #{result.check}\n  #{result.message.gsub("\n", "\n  ")}"
      end
    end
  end
end
