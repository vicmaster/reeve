# frozen_string_literal: true

module Reeve
  module Audit
    # One purge (specs/005 data-model "reeve_audit_retentions"): which checkpoint the ledger
    # was purged up to, what was removed, and the archive written, signed and chained to the
    # purge before it.
    #
    # Written by `bin/rails reeve:purge_ledger` through the retention connection, never this
    # model; the model only reads, for verification, and refuses to change one. As with
    # ChainEpoch, that protects against the library, not against raw SQL; the verifier reports
    # a record changed outside reeve.
    class RetentionRecord < ActiveRecord::Base
      self.table_name = "reeve_audit_retentions"

      before_update { raise ActiveRecord::ReadOnlyRecord, "a retention record is written once" }
      before_destroy { throw :abort }

      def readonly?
        persisted? || super
      end
    end
  end
end
