# frozen_string_literal: true

module Reeve
  # The ledger's Rake tasks, as `bin/rails -T` lists them (Reeve::Tasks.define).
  module Tasks
    # Each task's description, and the method of this module it runs.
    DESCRIPTIONS = {
      verify_ledger: "Verify the audit ledger's chain " \
                     "(exit 0 intact, 1 broken, 2 could not verify; LIMIT=, FORMAT=json)",
      checkpoint_ledger: "Checkpoint the audit ledger's chain to config.ledger_anchor " \
                         "(exit 0 made, 1 refused or the anchor failed)",
      purge_ledger: "Purge the audit ledger's oldest entries up to a checkpoint (THROUGH= or " \
                    "OLDER_THAN=Nd; ARCHIVE=path or NO_ARCHIVE=1; nothing removed without " \
                    "CONFIRM=1)",
      verify_archive: "Verify an archive reeve:purge_ledger wrote, on its own " \
                      "(ARCHIVE=path; exit 0 intact, 1 broken, 2 could not verify)",
      rotate_ledger_key: "Make config.ledger_key the ledger's current key epoch (exit 0 " \
                         "rotated or current, 1 refused; ACCEPT_UNVERIFIABLE=1 if the old key " \
                         "is lost)"
    }.freeze
  end
end
