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

    def limit_from(env)
      raw = env.fetch("LIMIT", Reeve::Audit::Chain::Verification::DEFAULT_LIMIT.to_s)
      Integer(raw, 10).tap { |limit| raise ArgumentError if limit.negative? }
    rescue ArgumentError, TypeError
      raise ArgumentError, "LIMIT must be a whole number of breaks to list, got #{raw.inspect}"
    end

    # The Rake task, defined on the current Rake application. Depends on :environment, so
    # the host's initializer — and with it the ledger key — is loaded first.
    def define
      extend Rake::DSL

      namespace :reeve do
        desc "Verify the audit ledger's chain " \
             "(exit 0 intact, 1 broken, 2 could not verify; LIMIT=, FORMAT=json)"
        task verify_ledger: :environment do
          exit Reeve::Tasks.verify_ledger
        end
      end
    end
  end
end
