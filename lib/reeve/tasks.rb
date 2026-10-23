# frozen_string_literal: true

require "json"

module Reeve
  # `bin/rails reeve:verify_ledger` (specs/002 FR-017, contracts/ledger-chain.md "Rake").
  #
  # A Ruby file rather than a .rake one on purpose: reeve.gemspec packages lib/**/*.rb, and a
  # .rake file would pass every spec in the working tree and be missing from the gem users
  # install. Registered by Reeve::Railtie; callable without Rake for anything else that
  # wants the same answer — a deploy gate, a scheduled job, a console.
  #
  #   status = Reeve::Tasks.verify_ledger(env: { "LIMIT" => "0" })
  module Tasks
    EXIT = { intact: 0, broken: 1, unverifiable: 2, no_chain: 2 }.freeze
    FORMATS = %w[text json].freeze
    ROTATE_EXIT = { rotated: 0, current: 0, refused: 1 }.freeze

    module_function

    # Verifies the ledger, writes the report to `out`, and returns the exit status:
    # 0 intact, 1 broken, 2 could not verify (unverifiable, or no chain).
    #
    # LIMIT caps the breaks listed in the text report (default 100; the totals are never
    # capped). FORMAT=json writes the whole result, every break, and ignores LIMIT.
    def verify_ledger(env: ENV, out: $stdout)
      format = env.fetch("FORMAT", "text")
      unless FORMATS.include?(format)
        raise ArgumentError, "FORMAT must be one of #{FORMATS.join(', ')}, got #{format.inspect}"
      end

      limit = limit_from(env)
      require "reeve/audit"
      result = Reeve::Audit::Chain.verify
      out.puts(format == "json" ? JSON.generate(result.as_json) : result.to_s(limit: limit))
      EXIT.fetch(result.status)
    end

    # Makes the configured ledger key the latest epoch's key (specs/003, contracts/
    # key-rotation.md), writes what happened to `out`, and returns the exit status: 0 rotated
    # or already current, 1 refused.
    #
    # ACCEPT_UNVERIFIABLE=1 opens the epoch even though the outgoing epoch's key is not
    # configured here — for a key that is lost, and only then.
    def rotate_ledger_key(env: ENV, out: $stdout)
      accept = accept_unverifiable_from(env)
      require "reeve/audit"
      rotation = Reeve::Audit::Chain.rotate_key!(accept_unverifiable: accept)
      out.puts(rotation.to_s)
      ROTATE_EXIT.fetch(rotation.status)
    end

    def accept_unverifiable_from(env)
      raw = env.fetch("ACCEPT_UNVERIFIABLE", "")
      return false if raw.empty?
      return true if raw == "1"

      raise ArgumentError, "ACCEPT_UNVERIFIABLE must be 1 or unset, got #{raw.inspect}"
    end

    def limit_from(env)
      raw = env.fetch("LIMIT", Reeve::Audit::Chain::Verification::DEFAULT_LIMIT.to_s)
      Integer(raw, 10).tap { |limit| raise ArgumentError if limit.negative? }
    rescue ArgumentError, TypeError
      raise ArgumentError, "LIMIT must be a whole number of breaks to list, got #{raw.inspect}"
    end

    # The Rake task, defined on the current Rake application. Depends on :environment, so
    # the host's initializer — and with it the ledger key — is loaded first.
    #
    # The DSL is borrowed by a throwaway object, so Reeve::Tasks itself never gains `task`,
    # `sh` and the rest of Rake's methods.
    def define
      Object.new.extend(Rake::DSL).instance_exec do
        namespace :reeve do
          desc "Verify the audit ledger's chain " \
               "(exit 0 intact, 1 broken, 2 could not verify; LIMIT=, FORMAT=json)"
          task verify_ledger: :environment do
            exit Reeve::Tasks.verify_ledger
          end

          desc "Make config.ledger_key the ledger's current key epoch (exit 0 rotated or " \
               "current, 1 refused; ACCEPT_UNVERIFIABLE=1 if the old key is lost)"
          task rotate_ledger_key: :environment do
            exit Reeve::Tasks.rotate_ledger_key
          end
        end
      end
    end
  end
end
