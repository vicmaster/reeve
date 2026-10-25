# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      module Retention
        # What a purge needs before it reads anything (specs/005 FR-004, FR-006, FR-007): a key,
        # an anchor, a retention connection that is not the application's, and somewhere to put
        # the archive, or leave to go without one. Each missing piece is a refusal that names it.
        class Preflight
          attr_reader :keyring, :guard

          def initialize(entry_class:, archive:, no_archive:)
            @keyring = Keyring.from(Reeve.config)
            @guard = Connection.new(Reeve.config.ledger_retention_connection,
                                    entry_class: entry_class)
            @archive = archive
            @no_archive = no_archive
          end

          def refusal
            return PurgeResult.refused(:no_key) unless keyring.signing?
            return PurgeResult.refused(:no_anchor) if Reeve.config.ledger_anchor.nil?

            PurgeResult.refused(guard.problem) if guard.problem
          end

          # Only a new purge writes an archive; a resumed one already did.
          def archive_refusal
            return nil if @no_archive
            return PurgeResult.refused(:no_archive_choice) if @archive.nil?
            return PurgeResult.refused(:archive_exists, detail: @archive) if File.exist?(@archive)
            return nil if writable_directory?

            PurgeResult.refused(:archive_unwritable, detail: @archive)
          end

          private

          def writable_directory?
            directory = File.dirname(@archive)
            File.directory?(directory) && File.writable?(directory)
          end
        end
      end
    end
  end
end
