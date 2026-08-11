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
    class Result
      attr_reader :check, :message, :details

      def self.passed(check:, message:, details: {})
        new(check: check, passed: true, message: message, details: details)
      end

      def self.failed(check:, message:, details: {})
        new(check: check, passed: false, message: message, details: details)
      end

      def initialize(check:, passed:, message:, details: {})
        @check   = check.to_s
        @passed  = passed ? true : false
        @message = message.to_s
        @details = details.freeze
        freeze
      end

      def passed?
        @passed
      end

      def failed?
        !@passed
      end

      def to_s
        message
      end

      def inspect
        "#<Reeve::Testing::Result #{check} #{passed? ? 'passed' : 'failed'} " \
          "#{message.inspect}>"
      end
    end
  end
end
