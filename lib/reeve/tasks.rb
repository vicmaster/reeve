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
    #
    # Checks the ledger against config.ledger_anchor's checkpoints, if one is configured
    # (specs/004). CHECKPOINTS=path reads them from a file of checkpoint lines instead, and
    # CHECKPOINTS= (empty) verifies without any. A checkpoint that cannot be read is exit 2.
    # FROM=latest walks from the highest checkpoint instead of the genesis.
    def verify_ledger(env: ENV, out: $stdout)
      format = env.fetch("FORMAT", "text")
      unless FORMATS.include?(format)
        raise ArgumentError, "FORMAT must be one of #{FORMATS.join(', ')}, got #{format.inspect}"
      end

      limit = limit_from(env)
      require "reeve/audit"
      result = Reeve::Audit::Chain.verify(checkpoints: checkpoints_from(env), from: from_env(env))
      out.puts(format == "json" ? JSON.generate(result.as_json) : result.to_s(limit: limit))
      EXIT.fetch(result.status)
    rescue Reeve::CheckpointError => e
      out.puts("reeve ledger: #{e.message}; nothing was verified")
      EXIT.fetch(:unverifiable)
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
      status = ROTATE_EXIT.fetch(rotation.status)
      return status unless rotation.rotated? && Reeve.config.ledger_anchor

      checkpoint_after_rotation(out)
    end

    # Pins the epoch just opened, which no entry names yet (specs/004 FR-008). A failed anchor
    # fails the task but does not undo the rotation: the epoch is open either way.
    def checkpoint_after_rotation(out)
      result = Reeve::Audit::Chain.checkpoint!
      out.puts(result.to_s)
      result.made? && !result.anchor_failed? ? 0 : 1
    end

    # Makes a checkpoint of the ledger's chain and hands it to config.ledger_anchor (specs/004,
    # contracts/anchoring.md), writes what happened and the checkpoint's line to `out`, and
    # returns the exit status: 0 made (and published, if there is an anchor), 1 refused or the
    # anchor failed. The line is printed either way, so a failed store does not lose it.
    def checkpoint_ledger(env: ENV, out: $stdout)
      require "reeve/audit"
      result = Reeve::Audit::Chain.checkpoint!
      out.puts(result.to_s)
      result.made? && !result.anchor_failed? ? 0 : 1
    end

    def from_env(env)
      raw = env.fetch("FROM", "")
      return nil if raw.empty?
      return :latest if raw == "latest"

      raise ArgumentError, "FROM must be latest or unset, got #{raw.inspect}"
    end

    # nil (the configured anchor's) unless CHECKPOINTS is set.
    def checkpoints_from(env)
      return nil unless env.key?("CHECKPOINTS")

      path = env["CHECKPOINTS"].to_s
      return [] if path.empty?
      raise Reeve::CheckpointError, "no checkpoint file at #{path}" unless File.file?(path)

      Reeve::Audit::FileAnchor.new(path).checkpoints
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

          desc "Checkpoint the audit ledger's chain to config.ledger_anchor " \
               "(exit 0 made, 1 refused or the anchor failed)"
          task checkpoint_ledger: :environment do
            exit Reeve::Tasks.checkpoint_ledger
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
