# frozen_string_literal: true

module Reeve
  module Audit
    # The ledger's chain record: one row holding the genesis and the head (specs/002
    # data-model "reeve_audit_chains").
    #
    # The genesis is link 0 — when the chain started, how many rows preceded it, and the
    # digest the first chained row links to. It is written once, with the first chained
    # row, and the model refuses to change it afterwards. The head is the latest sequence
    # and digest; Chain advances it with SQL of its own, inside the same transaction as
    # the row it points at, so it is never updated through this model.
    #
    # As with Entry, this protects against the library, not against raw SQL. A role that
    # can UPDATE this table can rewind the head; that is one of the stated limits of the
    # chain, and the verifier's job is to report what it can.
    class ChainRecord < ActiveRecord::Base
      self.table_name = "reeve_audit_chains"

      # Always this. A name rather than a primary key, because ids change on restore.
      LEDGER = "ledger"

      GENESIS_COLUMNS = %w[
        name genesis_at pre_chain_count pre_chain_unchained_count genesis_key_id genesis_digest
      ].freeze

      attr_readonly(*GENESIS_COLUMNS)

      # attr_readonly ignores the change silently on Rails 7.0 and raises from 7.1; this
      # makes every version refuse it out loud.
      before_update do
        changed = changed_attribute_names_to_save & GENESIS_COLUMNS
        unless changed.empty?
          raise ActiveRecord::ReadOnlyRecord,
                "the genesis of the ledger chain is written once; refused to change " \
                "#{changed.join(', ')}"
        end
      end

      before_destroy { throw :abort }

      def self.ledger
        find_by(name: LEDGER)
      end
    end
  end
end
