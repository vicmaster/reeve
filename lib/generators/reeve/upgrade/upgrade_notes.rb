# frozen_string_literal: true

module Reeve
  module Generators
    # What `reeve:upgrade` tells the host after writing a step whose contract changes more
    # than the table. The host is reading this output at exactly the moment they need it.
    module UpgradeNotes
      KEY_LINE = "config.ledger_key = " \
                 'Rails.application.key_generator.generate_key("reeve audit ledger", 32)'

      # Contract 3 changes what the application must configure, not only the table: without
      # a key, every guarded call fails closed once the migration runs.
      CHAIN = <<~CHAIN.freeze

        The ledger is now chained (contract 3). Add this line to config/initializers/reeve.rb
        before you deploy, or every guarded call fails closed:

          #{KEY_LINE}

        It derives the key from secret_key_base, so rotating secret_key_base rotates the
        ledger key: keep the old derived key in config.retired_ledger_keys, or entries it
        signed become unverifiable. A dedicated key avoids that coupling.

        Very large ledger on PostgreSQL? The migration builds a unique index that blocks
        writes while it scans; the migration's header shows how to build it with
        algorithm: :concurrently instead.
      CHAIN

      # Contract 4 changes how a rotation is done, so the host learns the command here.
      EPOCHS = <<~EPOCHS

        The ledger now records key epochs (contract 4): the first chained write opens
        epoch 0 with the configured ledger key. To rotate the key later, set the new key
        as config.ledger_key, keep the old one in config.retired_ledger_keys, deploy, and run:

          bin/rails reeve:rotate_ledger_key

        The application role needs INSERT and SELECT on reeve_audit_chain_epochs.
      EPOCHS

      BY_CONTRACT = { 3 => CHAIN, 4 => EPOCHS }.freeze

      module_function

      # The notes for the contracts just written, oldest first.
      def for(contracts)
        contracts.filter_map { |contract| BY_CONTRACT[contract] }.join
      end
    end
  end
end
