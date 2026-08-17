# frozen_string_literal: true

require "active_record"
require "logger"
require "tmpdir"
require "fileutils"

# The one database connection the ActiveRecord-backed specs share.
#
# It exists because there are two such harnesses — the authorization records and the
# audit ledger — and `establish_connection` is process-wide: whichever ran second used to
# drop the other's schema on the floor.
#
# == Which database
#
# `DB=sqlite3` (the default), `DB=postgresql`, or `DB=mysql2`. The gem claims to work on
# every database ActiveRecord supports — the migration stores `invocation_id` as a string
# rather than a native `uuid` specifically to make that true — and a claim that only ever
# runs on SQLite is a claim nobody has checked. The three engines disagree about exactly
# the things this gem depends on: what `t.json` becomes, what a boolean literal is, what
# `change_column_default` does to a NOT NULL column, and how a savepoint behaves inside a
# transaction the caller opened.
#
# Install the driver for the one you want first: `DB=postgresql bundle install`.
module SpecDatabase
  SQLITE_PATH = File.join(Dir.tmpdir, "reeve-spec-#{Process.pid}.sqlite3")

  ADAPTERS = %w[sqlite3 postgresql mysql2].freeze

  class << self
    def adapter
      @adapter ||= begin
        name = ENV.fetch("DB", "sqlite3")
        unless ADAPTERS.include?(name)
          raise ArgumentError, "DB=#{name} is not one of #{ADAPTERS.join(', ')}"
        end

        name
      end
    end

    def sqlite?
      adapter == "sqlite3"
    end

    def connect!
      return if @connected

      ActiveRecord::Base.logger = nil
      ActiveRecord::Migration.verbose = false
      ActiveRecord::Base.establish_connection(configuration)
      prepare_server_database!
      @connected = true
    end

    private

    def configuration
      case adapter
      when "sqlite3"     then sqlite_configuration
      when "postgresql"  then server_configuration(encoding: "unicode")
      when "mysql2"      then server_configuration(encoding: "utf8mb4")
      end
    end

    # A file database rather than :memory:, because sqlite gives every *connection* its
    # own in-memory database, and the concurrency specs run invocations on their own
    # threads, which check out their own connections.
    def sqlite_configuration
      at_exit { FileUtils.rm_f(SQLITE_PATH) }
      { adapter: "sqlite3", database: SQLITE_PATH }
    end

    def server_configuration(extra)
      {
        adapter: adapter,
        database: ENV.fetch("DB_NAME", "reeve_test"),
        username: ENV.fetch("DB_USERNAME", default_username),
        password: ENV.fetch("DB_PASSWORD", nil),
        host: ENV.fetch("DB_HOST", "127.0.0.1"),
        port: ENV.fetch("DB_PORT", nil)&.to_i
      }.compact.merge(extra)
    end

    def default_username
      adapter == "postgresql" ? ENV.fetch("USER", "postgres") : "root"
    end

    # A server database outlives the process, so a table left behind by an earlier run —
    # at an older shape, from a spec that builds a deliberately wrong one — would be
    # inherited rather than rebuilt: `Ledger.prepare!` only creates a table that is
    # missing entirely. SQLite gets this for free by using a per-pid file.
    def prepare_server_database!
      return if sqlite?

      connection = ActiveRecord::Base.connection
      connection.tables.each { |table| connection.drop_table(table, force: :cascade) }
    end
  end
end

SpecDatabase.connect!
