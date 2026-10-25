# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # The ledger's purges (specs/005), as verification and the purge read them.
      module Retention
        # Every retention record, oldest first, in one query. None for a ledger never purged,
        # or one whose table has not been migrated: it verifies exactly as before.
        module Records
          module_function

          def read(entry_class:)
            present = entry_class.connection_pool.with_connection do |connection|
              connection.table_exists?(RetentionRecord.table_name)
            end
            present ? RetentionRecord.uncached { RetentionRecord.order(:purge).to_a } : []
          end
        end
      end
    end
  end
end
