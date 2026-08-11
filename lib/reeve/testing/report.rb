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

      def passed?
        failures.empty?
      end

      def failed?
        !passed?
      end

      def failures
        results.reject(&:passed?)
      end

      def passes
        results.select(&:passed?)
      end

      def size
        results.size
      end

      def to_s
        [summary, *failures.map { |result| detail(result) }].join("\n")
      end

      def inspect
        "#<Reeve::Testing::Report #{summary}>"
      end

      private

      def summary
        "reeve compliance: #{size} #{size == 1 ? 'check' : 'checks'}, " \
          "#{passes.size} passed, #{failures.size} failed"
      end

      def detail(result)
        "\nFAIL #{result.check}\n  #{result.message}"
      end
    end
  end
end
