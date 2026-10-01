# frozen_string_literal: true

module Reeve
  module Testing
    # What a check hands back: whether the guarantee held, the sentence explaining it, and
    # the structured facts behind the sentence.
    #
    # The message is built here and nowhere else. A front-end — an RSpec matcher, a
    # Minitest assertion, a rake task — reads +message+ and prints it; none of them
    # composes their own (FR-019). That is what makes the same violation read identically
    # from all three.
    #
    # A result is passed, failed, or skipped. Skipped is for a guarantee the run could not
    # establish either way — endpoint coverage with no inventory declared. Reporting that
    # as a pass would be the green that means "we did not look"; reporting it as a failure
    # would turn every build red over a question the host never asked. A skip is printed,
    # and shows up yellow in both test frameworks, so it is neither.
    class Result
      STATUSES = %i[passed failed skipped].freeze

      attr_reader :check, :message, :details, :status

      def self.passed(check:, message:, details: {})
        new(check: check, status: :passed, message: message, details: details)
      end

      def self.failed(check:, message:, details: {})
        new(check: check, status: :failed, message: message, details: details)
      end

      def self.skipped(check:, message:, details: {})
        new(check: check, status: :skipped, message: message, details: details)
      end

      def initialize(check:, status:, message:, details: {})
        unless STATUSES.include?(status)
          raise ArgumentError, "status must be one of #{STATUSES.inspect}, got #{status.inspect}"
        end

        @check   = check.to_s
        @status  = status
        @message = message.to_s
        @details = details.freeze
        freeze
      end

      def passed?
        status == :passed
      end

      def failed?
        status == :failed
      end

      def skipped?
        status == :skipped
      end

      def to_s
        message
      end

      def inspect
        "#<Reeve::Testing::Result #{check} #{status} " \
          "#{message.inspect}>"
      end
    end
  end
end
