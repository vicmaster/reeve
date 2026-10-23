# frozen_string_literal: true

module Reeve
  module Audit
    # One key epoch: the key that began signing the ledger at `first_sequence` (specs/003
    # data-model "reeve_audit_chain_epochs").
    #
    # Written by Chain — when a key first signs, or by `bin/rails reeve:rotate_ledger_key` —
    # through the ledger's own connection, inside the write that needs it. This model only
    # reads them, for verification, and refuses to change one: an epoch is written once.
    # As with ChainRecord, that protects against the library, not against raw SQL; the
    # verifier reports an epoch changed outside reeve.
    class ChainEpoch < ActiveRecord::Base
      self.table_name = "reeve_audit_chain_epochs"

      before_update { raise ActiveRecord::ReadOnlyRecord, "a key epoch is written once" }
      before_destroy { throw :abort }

      def readonly?
        persisted? || super
      end
    end
  end
end
