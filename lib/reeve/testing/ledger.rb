# frozen_string_literal: true

module Reeve
  module Testing
    # The checks' read-only window onto the audit ledger.
    #
    # It exists so that `require "reeve/testing"` stays loadable with no ActiveRecord in
    # the process (FR-020, SC-008): nothing here mentions +Reeve::Audit::Entry+ until a
    # check actually asks a question, and every question has an answer for the case where
    # the ledger is absent.
    #
    # A host with its own non-ActiveRecord recorder can pass any object with these six
    # methods as `ledger:` to any ledger-reading check.
    class Ledger
      def self.default
        new
      end

      def available?
        return false if entry_class.nil?

        entry_class.table_exists?
      rescue StandardError
        false
      end

      # Why not, in the words a developer can act on.
      def unavailable_reason
        return nil if available?
        if entry_class.nil?
          return "the audit ledger is not loaded — add `require \"reeve/audit\"` to your " \
                 "test helper, or pass a `ledger:` of your own"
        end

        "the #{entry_class.table_name} table does not exist — run `rails g reeve:install` " \
          "and migrate"
      end

      # A position in the ledger, taken before an invocation so the entries that
      # invocation wrote can be told apart from everything already there.
      def marker
        return nil unless available?

        entry_class.maximum(:id)
      end

      def entries_after(marker)
        return [] unless available?

        scope = entry_class.order(:id)
        marker.nil? ? scope.to_a : scope.where("id > ?", marker).to_a
      end

      def count
        available? ? entry_class.count : 0
      end

      def contract_version
        return nil unless entry_class.respond_to?(:contract_version)

        entry_class.contract_version
      end

      def columns
        return [] unless available?

        entry_class.column_names.map(&:to_s)
      end

      private

      def entry_class
        return @entry_class if defined?(@entry_class)

        @entry_class =
          if Reeve.const_defined?(:Audit, false) && Reeve::Audit.const_defined?(:Entry, false)
            Reeve::Audit::Entry
          end
      end
    end
  end
end
