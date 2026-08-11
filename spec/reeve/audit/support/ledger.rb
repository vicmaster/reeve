# frozen_string_literal: true

require "active_record"
require "reeve/audit"

# The ActiveRecord harness for the audit specs, and only for them.
#
# It lives outside spec/support on purpose: spec_helper auto-loads everything under
# spec/support, and the core specs must keep running in a process that has never seen
# ActiveRecord (SC-008, spec/load_safety_spec.rb). Audit specs require this file
# explicitly instead.
#
# The schema comes from the generated migration template rather than a hand-written
# schema block, so the specs cannot pass against a table the generator would not
# actually create.
module Ledger
  TEMPLATE = File.expand_path(
    "../../../../lib/generators/reeve/install/templates/create_audit_entries.rb.tt", __dir__
  )

  class << self
    def connect!
      return if @connected

      ActiveRecord::Migration.verbose = false
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      @connected = true
    end

    # The migration class the install generator copies into the host application.
    def migration_class
      @migration_class ||= begin
        source = File.read(TEMPLATE)
        if source.include?("<%")
          raise "#{TEMPLATE} contains ERB tags; the harness cannot render them"
        end

        Object.class_eval(source, TEMPLATE)
        Object.const_get(:CreateReeveAuditEntries)
      end
    end

    def migrate_up!
      connect!
      migration_class.new.migrate(:up)
    end

    def migrate_down!
      connect!
      migration_class.new.migrate(:down)
    end

    def table_exists?
      connect!
      ActiveRecord::Base.connection.table_exists?(Reeve::Audit::Entry.table_name)
    end

    # Idempotent: the table is created once per process and emptied per example, because
    # wrapping examples in a transaction would change the very write semantics R5 is
    # about (a ledger write that survives the tool's own rollback).
    def prepare!
      migrate_up! unless table_exists?
      clean!
    end

    def clean!
      Reeve::Audit::Entry.delete_all
    end

    def indexes
      connect!
      ActiveRecord::Base.connection.indexes(Reeve::Audit::Entry.table_name)
    end

    def columns
      connect!
      ActiveRecord::Base.connection.columns(Reeve::Audit::Entry.table_name)
    end
  end
end

RSpec.shared_context "with a ledger table" do
  before { Ledger.prepare! }
end

RSpec.configure do |config|
  config.include_context "with a ledger table", ledger: true
end
