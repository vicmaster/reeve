# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Reeve
  module Generators
    # `bin/rails generate reeve:install` — step two of the three-step adoption path
    # (Constitution VI). Writes an initializer and the ledger migration, and nothing else.
    #
    # The initializer deliberately ships with `principal_resolver` unset: it is the one
    # thing only the host can answer, and a plausible-looking guess would be worse than a
    # TODO, because the library fails closed until it is filled in.
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Creates the reeve initializer and the audit ledger migration."

      def create_initializer
        template "initializer.rb.tt", "config/initializers/reeve.rb"
      end

      def create_migration_file
        migration_template(
          "create_audit_entries.rb.tt",
          "db/migrate/create_reeve_audit_entries.rb"
        )
      end

      def report_next_step
        say <<~NEXT

          reeve is installed. Two things left:

            1. Fill in `principal_resolver` in config/initializers/reeve.rb.
               Until you do, every guarded call denies with `no_principal`.
            2. Run `bin/rails db:migrate` to create the audit ledger.

          Then add `guard_with SomePolicy` to a tool.

          Upgrading an existing ledger later? Use `rails g reeve:upgrade`, not this
          generator — Rails resolves a migration by name, so re-running install cannot
          deliver a shape change to a table that already exists.
        NEXT
      end
    end
  end
end
