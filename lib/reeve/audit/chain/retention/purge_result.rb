# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # What `bin/rails reeve:purge_ledger` did, or why it did nothing (specs/005 data-model,
      # contracts/retention.md). A value, so a script can act on it without reading the text.
      #
      #   :dry_run           — what a run with CONFIRM=1 would remove; nothing removed
      #   :purged            — removed through `through`, recorded as retention record `purge`
      #   :nothing_to_purge  — no checkpoint above the current boundary qualifies
      #   :refused           — nothing removed; `reason` says why
      class PurgeResult
        PREFIX = "reeve ledger purge:"
        AGAIN = "run again with CONFIRM=1"

        FIELDS = %i[status reason detail from through through_made_at removed_chained
                    removed_pre_chain archive archive_sha256 purge resumed warnings].freeze

        REFUSALS = {
          no_key: "no ledger key configured (config.ledger_key)",
          no_anchor: "no anchor configured (config.ledger_anchor): a purge must stop at a " \
                     "checkpoint kept outside the database",
          no_retention_connection: "no retention connection configured " \
                                   "(config.ledger_retention_connection)",
          other_database: "config.ledger_retention_connection reaches another database than " \
                          "the ledger's",
          application_role: "config.ledger_retention_connection connects as the application's " \
                            "own database user; the purge must run on a role the application " \
                            "does not use",
          no_checkpoint: "no checkpoint the anchor holds is at that sequence (nearest below: %s, " \
                         "above: %s)",
          not_intact: "the ledger does not verify intact, and a purge never removes what it " \
                      "cannot prove: %s",
          no_archive_choice: "give ARCHIVE=path to keep the purged entries, or NO_ARCHIVE=1 to " \
                             "delete them without one",
          archive_exists: "the archive %s already exists; an archive is never overwritten",
          archive_unwritable: "the archive %s cannot be written there",
          purge_running: "another purge took the next retention record number; run again once " \
                         "it is done"
        }.freeze

        attr_reader(*FIELDS)

        def self.refused(reason, detail: nil)
          new(status: :refused, reason: reason, detail: detail)
        end

        def self.nothing(reason, current:)
          new(status: :nothing_to_purge, reason: reason, through: current)
        end

        def self.from(plan, status, **fields)
          new(status: status, from: plan.from, through: plan.through,
              through_made_at: plan.checkpoint.made_at, removed_chained: plan.removed_chained,
              removed_pre_chain: plan.removed_pre_chain, **fields)
        end

        def self.resumed(record, removed, warnings:)
          new(status: :purged, from: record.previous_through + 1, through: record.through_sequence,
              purge: record.purge, removed_chained: record.removed_chained,
              removed_pre_chain: record.removed_pre_chain, resumed: removed,
              archive_sha256: record.archive_sha256, warnings: warnings)
        end

        def initialize(status:, warnings: [], **fields)
          @status = status
          @warnings = warnings.freeze
          (FIELDS - %i[status warnings]).each do |name|
            instance_variable_set(:"@#{name}", fields[name])
          end
          freeze
        end

        def dry_run? = status == :dry_run
        def purged? = status == :purged
        def refused? = status == :refused

        def to_s
          [first_line, *warnings.map { |warning| "warning: #{warning}" }].join("\n")
        end

        private

        def first_line
          case status
          when :dry_run then "#{PREFIX} WOULD PURGE — #{removal}; #{archive_text}; #{AGAIN}"
          when :purged then "#{PREFIX} PURGED — #{purged_text}"
          when :nothing_to_purge then "#{PREFIX} NOTHING TO PURGE — #{nothing_text}"
          else "#{PREFIX} REFUSED — #{refusal}; nothing was removed"
          end
        end

        def purged_text
          record = "#{removal}; retention record #{purge}"
          return "#{record} (resumed; #{n(resumed)} rows removed this run)" if resumed

          "#{record}; #{archive_text}"
        end

        def removal
          made = through_made_at ? " (#{AnchorText.made_on(through_made_at)})" : ""
          "sequences #{n(from || 1)}–#{n(through)} through checkpoint ##{n(through)}#{made}: " \
            "#{n(removed_chained)} chained entries and #{n(removed_pre_chain)} pre-chain rows"
        end

        def archive_text
          return "no archive written (NO_ARCHIVE=1)" if archive.nil?
          return "archive to #{archive}" if dry_run?

          "archive #{archive} (sha256 #{archive_sha256})"
        end

        def nothing_text
          where = "above the current boundary (##{n(through)})"
          return "no checkpoint old enough #{where}" unless reason == :at_or_below

          "the ledger is already purged through that sequence #{where}"
        end

        def refusal
          template = REFUSALS.fetch(reason)
          return template unless template.include?("%s")

          format(template, *Array(detail))
        end

        def n(value)
          Report.number(value.to_i)
        end
      end
    end
  end
end
