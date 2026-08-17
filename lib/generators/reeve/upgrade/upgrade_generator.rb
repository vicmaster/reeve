# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Reeve
  module Generators
    # `bin/rails generate reeve:upgrade` — brings an existing ledger up to the audit-entry
    # contract this version of the gem writes.
    #
    # Why this exists as a second generator rather than as a re-run of `reeve:install`:
    # Rails resolves a migration by name, so `install` on a host that already has
    # `create_reeve_audit_entries` reports `identical` and emits nothing, or — once the
    # template has changed, which is exactly the upgrade case — offers to overwrite a
    # migration that has already run. Overwriting an applied migration does not touch the
    # database and destroys the record of what was applied, so the one thing a host must
    # never be told to do about an out-of-date ledger is run the install generator again.
    #
    # What it emits is decided by the table, not by a version number the host might have
    # recorded wrongly or not at all: each step declares the columns it adds, and a step
    # whose columns are all present has already been applied. That makes running this on a
    # current ledger a no-op it can report rather than a duplicate migration.
    class UpgradeGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      TABLE = "reeve_audit_entries"

      # The ladder, oldest first. One entry per contract bump that touches the table.
      #
      # `adds` is what makes a step detectable, so it must name every column the step
      # creates. A step that changes a column without adding one cannot be detected this
      # way and needs its own predicate — see the additive-only rule in
      # contracts/audit-entry.md, which exists so that stays hypothetical: an append-only
      # ledger cannot be backfilled, so a column that is not additive has no honest value
      # to give the rows already written.
      STEPS = [
        {
          contract: 2,
          adds: %w[contract_version],
          template: "add_contract_version_to_reeve_audit_entries.rb.tt",
          destination: "add_contract_version_to_reeve_audit_entries.rb"
        }
      ].freeze

      source_root File.expand_path("templates", __dir__)

      desc "Brings an existing reeve audit ledger up to the current audit-entry contract."

      def verify_ledger_exists
        return if table_exists?

        say <<~MISSING

          There is no #{TABLE} table to upgrade.

          This generator is for a ledger that already exists. For a new one:

            bin/rails generate reeve:install
            bin/rails db:migrate
        MISSING

        # Not an exception: "you wanted the other generator" is a normal thing to get
        # wrong, and a backtrace would suggest reeve broke.
        @halted = true
      end

      def create_upgrade_migrations
        return if @halted

        pending = STEPS.reject { |step| applied?(step) }
        return @nothing_to_do = true if pending.empty?

        pending.each do |step|
          migration_template(step[:template], "db/migrate/#{step[:destination]}")
        end

        @emitted = pending
      end

      def report_next_step
        return if @halted

        say(@nothing_to_do ? up_to_date_message : pending_message)
      end

      private

      def up_to_date_message
        <<~CURRENT

          #{TABLE} is already at audit-entry contract #{STEPS.last[:contract]}. Nothing to do.
        CURRENT
      end

      def pending_message
        <<~NEXT

          #{@emitted.size} migration#{'s' if @emitted.size != 1} written, taking the ledger
          to audit-entry contract #{@emitted.last[:contract]}. Run:

            bin/rails db:migrate

          Existing rows are stamped with the contract they were actually written under,
          not with the current one.
        NEXT
      end

      # Asked of the table rather than of a version the host recorded: the table is the
      # thing being changed, and it is the only party that cannot be out of date about
      # itself.
      def applied?(step)
        (step[:adds] - existing_columns).empty?
      end

      def existing_columns
        @existing_columns ||= connection.columns(TABLE).map(&:name)
      end

      def table_exists?
        connection.table_exists?(TABLE)
      rescue StandardError
        false
      end

      def connection
        ActiveRecord::Base.connection
      end
    end
  end
end
