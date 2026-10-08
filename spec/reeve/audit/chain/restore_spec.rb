# frozen_string_literal: true

require "open3"
require "securerandom"
require "tmpdir"
require_relative "../support/ledger"

# specs/002 T024 / FR-002, SC-002: the chain survives a dump and restore on the same engine.
#
# A real dump, through each engine's own tool, so every value makes the trip as text —
# which is what a backup restored into a fresh database does to it. The primary keys are
# renumbered afterwards, as a restore into a database with its own sequences would leave
# them: the digest must not depend on them (FR-002).
#
# Where the engine's dump tool is missing, or older than the server (pg_dump refuses to
# dump a newer server), the example is pending with that reason — never passed. Point it at
# a matching client with REEVE_PG_BIN or REEVE_MYSQL_BIN (a directory).
RSpec.describe "a chained ledger dumped and restored" do
  let(:config) { ActiveRecord::Base.connection_db_config.configuration_hash }
  let(:tables) { %w[reeve_audit_entries reeve_audit_chains] }

  before do
    Ledger.prepare!
    chain = Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry)
    20.times do |i|
      chain.append!(
        invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a", tool_name: "t",
        arguments: { "z" => i, "a" => { "n" => 1.0e20, "s" => "añ 🎉" } }, outcome: "allow",
        rule: "r", record_ids: [i.to_s], guard: "policy", contract_version: Reeve::Audit::CONTRACT_VERSION
      )
    end
  end

  after { Reeve::Audit::Entry.reset_column_information }

  def run!(*command, stdin_data: nil)
    output, status = Open3.capture2e(environment, *command, stdin_data: stdin_data)
    raise "#{command.first} failed: #{output}" unless status.success?

    output
  end

  def tool(name, override)
    directory = ENV.fetch(override, nil)
    path = directory ? File.join(directory, name) : name
    _, status = Open3.capture2e("which", path)
    status.success? || File.executable?(path) ? path : nil
  end

  def environment
    case SpecDatabase.adapter
    when "postgresql" then { "PGPASSWORD" => config[:password].to_s }
    when "mysql2" then { "MYSQL_PWD" => config[:password].to_s }
    else {}
    end
  end

  def server_args(flags)
    args = []
    args += [flags[:host], config[:host].to_s] if config[:host]
    args += [flags[:port], config[:port].to_s] if config[:port]
    args += [flags[:user], config[:username].to_s] if config[:username]
    args
  end

  def dump
    case SpecDatabase.adapter
    when "sqlite3"    then dump_sqlite
    when "postgresql" then dump_postgresql
    when "mysql2"     then dump_mysql
    end
  end

  # `.dump <table>` emits the table and its rows but not its indexes (SQLite 3.43), so the
  # indexes are taken from `.schema`, which lists them. A whole-database `.dump` includes
  # them; dumping two tables out of a shared spec database is what needs the help.
  def dump_sqlite
    sqlite = tool("sqlite3", "REEVE_SQLITE_BIN") or skip("sqlite3 is not installed")
    rows = run!(sqlite, config[:database], *tables.map { |t| ".dump #{t}" })
    indexes = run!(sqlite, config[:database], *tables.map { |t| ".schema #{t}" })
              .lines.grep(/\ACREATE (UNIQUE )?INDEX/i).join
    [sqlite, rows + indexes]
  end

  def dump_postgresql
    pg_dump = tool("pg_dump", "REEVE_PG_BIN") or skip("pg_dump is not installed")
    psql = tool("psql", "REEVE_PG_BIN") or skip("psql is not installed")
    require_client_not_older_than_server!(pg_dump)

    flags = { host: "-h", port: "-p", user: "-U" }
    sql = run!(pg_dump, *server_args(flags), "--no-owner", "--no-privileges",
               *tables.flat_map { |t| ["-t", t] }, config[:database])
    [[psql, *server_args(flags), "-q", "-v", "ON_ERROR_STOP=1", config[:database]], sql]
  end

  def require_client_not_older_than_server!(pg_dump)
    client = run!(pg_dump, "--version")[/\d+/].to_i
    server = ActiveRecord::Base.connection.select_value("SHOW server_version")[/\d+/].to_i
    skip("pg_dump #{client} cannot dump PostgreSQL #{server}; set REEVE_PG_BIN") if client < server
  end

  def dump_mysql
    mysqldump = tool("mysqldump", "REEVE_MYSQL_BIN") or skip("mysqldump is not installed")
    mysql = tool("mysql", "REEVE_MYSQL_BIN") or skip("mysql is not installed")
    flags = { host: "-h", port: "-P", user: "-u" }
    sql = run!(mysqldump, *server_args(flags), "--protocol=TCP", "--skip-comments",
               "--no-tablespaces", config[:database], *tables)
    [[mysql, *server_args(flags), "--protocol=TCP", config[:database]], sql]
  end

  def restore(loader, sql)
    connection = ActiveRecord::Base.connection
    tables.each { |table| connection.drop_table(table, force: :cascade) }
    connection.disconnect! if SpecDatabase.sqlite?

    if SpecDatabase.sqlite?
      run!(loader, config[:database], stdin_data: sql)
    else
      run!(*loader, stdin_data: sql)
    end
    ActiveRecord::Base.connection.reconnect! if SpecDatabase.sqlite?
    Reeve::Audit::Entry.reset_column_information
  end

  it "verifies intact after the round trip, with every primary key renumbered" do
    expect(Reeve::Audit::Chain.verify.status).to eq(:intact)
    ids_before = Reeve::Audit::Entry.order(:chain_sequence).pluck(:id)

    loader, sql = dump
    restore(loader, sql)
    Reeve::Audit::Entry.where("id > 0").update_all("id = id + 100000")

    expect(Reeve::Audit::Entry.order(:chain_sequence).pluck(:id)).to eq(ids_before.map { |id| id + 100_000 })
    expect(ActiveRecord::Base.connection.indexes(:reeve_audit_chains).map(&:columns)).to include(["name"])
    result = Reeve::Audit::Chain.verify
    expect(result.status).to eq(:intact)
    expect(result.covered).to eq(1..20)
  end
end
