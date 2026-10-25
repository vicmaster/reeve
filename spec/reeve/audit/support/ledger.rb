# frozen_string_literal: true

require "active_record"
require "reeve/audit"
require "support/optional/database"

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

  CHAIN_TABLES = %w[reeve_audit_chains reeve_audit_chain_epochs].freeze

  class << self
    # The connection is shared with the other ActiveRecord-backed specs; see
    # spec/support/optional/database.rb for why it is one connection and one file.
    def connect!
      SpecDatabase.connect!
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
    # A ledger is its two tables. One without the other is what a spec that broke the
    # schema on purpose leaves behind, and `clean!` would fail on it — so a half-present
    # ledger is dropped and rebuilt rather than inherited by the next example.
    def prepare!
      connect!
      connection = ActiveRecord::Base.connection
      present = [Reeve::Audit::Entry.table_name, *CHAIN_TABLES].map { |t| connection.table_exists?(t) }
      unless present.all? && Reeve::Audit::Entry.column_names.include?("chain_epoch")
        [Reeve::Audit::Entry.table_name, *CHAIN_TABLES].each { |t| connection.drop_table(t, if_exists: true) }
        migrate_up!
        Reeve::Audit::Entry.reset_column_information
      end
      clean!
    end

    def clean!
      Reeve::Audit::Entry.delete_all
      CHAIN_TABLES.each { |table| ActiveRecord::Base.connection.delete("DELETE FROM #{table}") }
      scratch.delete_all
    end

    # Tampering as someone with database access and no key would do it (specs/004): raw SQL,
    # past every model guard.
    #
    # Removes every entry after `after` and rewinds the head to the entry left, so what
    # remains is a shorter chain that verifies on its own.
    def truncate_tail!(after:)
      connection = ActiveRecord::Base.connection
      connection.delete("DELETE FROM #{Reeve::Audit::Entry.table_name} WHERE chain_sequence > #{Integer(after)}")
      digest = if after.zero?
                 connection.select_value("SELECT genesis_digest FROM reeve_audit_chains")
               else
                 connection.select_value("SELECT chain_digest FROM #{Reeve::Audit::Entry.table_name} " \
                                         "WHERE chain_sequence = #{Integer(after)}")
               end
      connection.update("UPDATE reeve_audit_chains SET head_sequence = #{Integer(after)}, " \
                        "head_digest = #{connection.quote(digest)}")
    end

    # Every entry, the chain record and every epoch: the whole ledger, gone.
    def empty!
      connection = ActiveRecord::Base.connection
      [Reeve::Audit::Entry.table_name, *CHAIN_TABLES].each { |table| connection.delete("DELETE FROM #{table}") }
    end

    def delete_epoch!(number)
      ActiveRecord::Base.connection.delete("DELETE FROM reeve_audit_chain_epochs WHERE epoch = #{Integer(number)}")
    end

    # A throwaway table standing in for the host's own data, so a spec about a tool that
    # rolls its work back can assert the rollback happened rather than assume it.
    def scratch
      @scratch ||= begin
        connect!
        connection = ActiveRecord::Base.connection
        unless connection.table_exists?(:ledger_scratch)
          connection.create_table(:ledger_scratch) { |t| t.string :name }
        end
        Class.new(ActiveRecord::Base) { self.table_name = "ledger_scratch" }
      end
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

# A fixed key for every example that can write the ledger (specs/002 T017). From contract
# 3 a write without a key fails closed — the right behaviour for a host, and the wrong one
# for 600 examples that are about something else. Set after spec_helper resets the
# configuration, which is why it is a hook here rather than a constant there. Specs that
# exercise the missing-key path unset it themselves.
module Ledger
  TEST_KEY = "reeve-spec-ledger-key-not-a-secret-0123456789"
end

# An anchor for specs (specs/004): keeps the lines it is given, in memory, and raises when told
# to, so a spec can watch what was published without a file.
module Ledger
  class RecordingAnchor
    attr_reader :lines

    def initialize(error: nil)
      @lines = []
      @error = error
    end

    def publish(line)
      raise @error if @error

      @lines << line
    end

    def checkpoints
      @lines.dup
    end
  end
end

RSpec.configure do |config|
  config.include_context "with a ledger table", ledger: true
  config.before { Reeve.config.ledger_key = Ledger::TEST_KEY }
end
