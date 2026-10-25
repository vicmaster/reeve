# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # Chain.checkpoint! (specs/004), Chain.purge! and Chain.verify_archive (specs/005), kept
      # beside the code they enter rather than in the class that appends.
      module Entrypoints
        # Makes a checkpoint of where the chain has reached and hands it to `anchor`; returns a
        # CheckpointResult. `bin/rails reeve:checkpoint_ledger` runs it.
        def checkpoint!(entry_class: Entry, anchor: Reeve.config.ledger_anchor)
          CheckpointResult.make!(entry_class: entry_class, anchor: anchor)
        end

        # Purges the chain's oldest entries up to a checkpoint and returns a PurgeResult.
        # `bin/rails reeve:purge_ledger` runs it.
        def purge!(entry_class: Entry, **options)
          Retention::Purge.new(entry_class: entry_class, **options).call
        end

        # Verifies an archive a purge wrote, on its own. With `keys:`, with those keys alone.
        def verify_archive(path, keys: nil, entry_class: Entry)
          Retention::ArchiveCheck.new(path, keyring: Keyring.verifying(keys),
                                            entry_class: entry_class).call
        end
      end
    end
  end
end
