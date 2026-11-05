# frozen_string_literal: true

# A ledger writer in a process of its own, for the purge benchmark (specs/005 writer-wait.md).
# It shares no GVL with the purge, so a slow write here is time spent waiting on the database.
#
#   ruby writer.rb OUTPUT
#
# Takes the database configuration (JSON) from REEVE_WRITER_DB and the ledger key from
# REEVE_WRITER_KEY, then appends until SIGTERM. Each write adds a line to OUTPUT: its start
# and its duration, in seconds on CLOCK_MONOTONIC. A write that raises ends the run with an
# "error ..." line and exit status 1.
require "json"
require "securerandom"
require "active_record"
require "reeve"
require "reeve/audit"

stop = false
Signal.trap("TERM") { stop = true }
# A parent killed outright never sends TERM; the writer stops when it is orphaned instead.
parent = Process.ppid

File.open(ARGV.fetch(0), "w") do |output|
  output.sync = true
  ActiveRecord::Base.logger = nil
  ActiveRecord::Base.establish_connection(JSON.parse(ENV.fetch("REEVE_WRITER_DB"), symbolize_names: true))
  Reeve.config.ledger_key = ENV.fetch("REEVE_WRITER_KEY")
  chain = Reeve::Audit::Chain.new(entry_class: Reeve::Audit::Entry)

  until stop || Process.ppid != parent
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    chain.append!(invocation_id: SecureRandom.uuid, occurred_at: Time.now, agent_id: "a",
                  tool_name: "t", arguments: {}, outcome: "allow", rule: "r", record_ids: [],
                  guard: "policy", contract_version: Reeve::Audit::CONTRACT_VERSION)
    output.write("#{started} #{Process.clock_gettime(Process::CLOCK_MONOTONIC) - started}\n")
  end
rescue StandardError => e
  output.write("error #{e.class}: #{e.message}\n")
  exit 1
end
