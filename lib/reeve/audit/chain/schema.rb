# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # Whether the ledger has the shape this reeve writes: every chain column and, from
      # contract 4, the epochs table (specs/003 FR-018). A table one contract behind fails
      # with the fix named.
      #
      # The columns are checked before every write — ActiveRecord caches them, so that costs
      # nothing. The epochs table is not: asking the catalog would be a query per guarded
      # call (FR-019b), so its absence is diagnosed only once the database has refused a
      # write that needed it.
      class Schema
        def initialize(entry_class)
          @entry_class = entry_class
        end

        def require_columns!
          missing = COLUMNS - entry_class.column_names
          outdated!("#{entry_class.table_name} is missing #{missing.join(', ')}") if missing.any?
        end

        # Runs the write; if the database refuses it, names a missing epochs table as the
        # cause. Recorder builds a Chain per write, so asking up front would be a catalog
        # query per guarded call.
        def explaining
          yield
        rescue ActiveRecord::StatementInvalid => e
          explain!(e)
        end

        # Re-raises `error` unless the epochs table is what the ledger lacks. A ledger with no
        # entries table at all is not an older contract but a missing ledger, and keeps the
        # database's own error.
        def explain!(error)
          missing = entry_class.connection_pool.with_connection do |connection|
            !connection.table_exists?(EPOCHS_TABLE) &&
              connection.table_exists?(entry_class.table_name)
          end
          raise error unless missing

          outdated!("there is no #{EPOCHS_TABLE} table")
        end

        private

        attr_reader :entry_class

        def outdated!(problem)
          raise ConfigurationError,
                "#{problem}: the ledger is at an older audit-entry contract than this reeve " \
                "writes (#{CONTRACT_VERSION}). Run `bin/rails generate reeve:upgrade` and " \
                "`bin/rails db:migrate`."
        end
      end
    end
  end
end
