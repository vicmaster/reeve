# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # Whether the ledger has the shape this reeve writes: every chain column and, from
      # contract 4, the epochs table (specs/003 FR-018). A table one contract behind fails
      # here, naming the fix.
      class Schema
        def initialize(entry_class)
          @entry_class = entry_class
        end

        def require!
          missing = COLUMNS - entry_class.column_names
          problems = []
          problems << "#{entry_class.table_name} is missing #{missing.join(', ')}" if missing.any?
          problems << "there is no #{EPOCHS_TABLE} table" if missing_epochs_table?
          return if problems.empty?

          raise ConfigurationError,
                "#{problems.join(' and ')}: the ledger is at an older audit-entry contract " \
                "than this reeve writes (#{CONTRACT_VERSION}). Run " \
                "`bin/rails generate reeve:upgrade` and `bin/rails db:migrate`."
        end

        private

        attr_reader :entry_class

        # Remembered once found — the check is a schema query, and a Chain is shared by every
        # thread that writes — but asked again while absent, so a migration run under a live
        # process is picked up. Every thread that remembers it remembers the same `true`.
        #
        # A ledger with no entries table at all is not an older contract, it is a missing
        # ledger, and the write is left to fail with the database's own error.
        def missing_epochs_table?
          return false if @epochs_table

          entry_class.connection_pool.with_connection do |connection|
            @epochs_table = connection.table_exists?(EPOCHS_TABLE)
            !@epochs_table && connection.table_exists?(entry_class.table_name)
          end
        end
      end
    end
  end
end
