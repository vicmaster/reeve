# frozen_string_literal: true

require "json"

module Reeve
  module Audit
    class Chain
      # A signed statement of where the chain reached (specs/004, contracts/checkpoint-v1.md):
      # the genesis, the head, and the latest key epoch, which pins every earlier epoch because
      # epoch digests are chained to each other and to the genesis.
      #
      # Kept outside the database by the host's anchor, so that removing entries and rewinding
      # the head, or emptying the ledger, leaves a witness the database cannot change. It
      # asserts where the chain reached, not that the chain was intact, and its `made_at` is
      # the producing host's clock: nothing in verification depends on it.
      #
      # It holds digests, counts, a key fingerprint, a time and versions — never entry content,
      # never a key — so it can be stored where the ledger's data must not be.
      class Checkpoint
        FORMAT = "reeve-ledger-checkpoint-v1"

        TIME_FORMAT = "%Y-%m-%dT%H:%M:%S.%6NZ"

        INTEGER = [Integer].freeze
        STRING = [String].freeze
        OPTIONAL_INTEGER = [Integer, NilClass].freeze
        OPTIONAL_STRING = [String, NilClass].freeze

        TYPES = {
          "format" => STRING, "ledger" => STRING, "genesis_digest" => STRING,
          "pre_chain_count" => INTEGER, "pre_chain_unchained_count" => INTEGER,
          "head_sequence" => INTEGER, "head_digest" => STRING,
          "epoch" => OPTIONAL_INTEGER, "epoch_digest" => OPTIONAL_STRING,
          "key_id" => STRING, "made_at" => STRING, "reeve_version" => STRING,
          "signature" => STRING
        }.freeze

        TYPES.each_key { |field| define_method(field) { @values[field] } }

        # `state` is the chain record's columns as one read returned them; `epoch` the latest
        # epoch's number and digest, or nil for a ledger with none.
        def self.build(state:, epoch:, keyring:)
          values = {
            "format" => FORMAT, "ledger" => ChainRecord::LEDGER,
            "genesis_digest" => state["genesis_digest"],
            "pre_chain_count" => Integer(state["pre_chain_count"]),
            "pre_chain_unchained_count" => Integer(state["pre_chain_unchained_count"]),
            "head_sequence" => Integer(state["head_sequence"]),
            "head_digest" => state["head_digest"],
            "epoch" => epoch && epoch[:epoch], "epoch_digest" => epoch && epoch[:epoch_digest],
            "key_id" => keyring.signing_id, "made_at" => Time.now.utc.strftime(TIME_FORMAT),
            "reeve_version" => Reeve::VERSION
          }
          signature = Canonical.checkpoint_signature(keyring.signing_secret, values)
          new(values.merge("signature" => signature))
        end

        # `position` is the line's place in its list, from 1, for the error that names it.
        def self.parse(line, position:)
          values = JSON.parse(line.to_s)
          reason = problem(values)
          raise CheckpointError.new(reason, position: position) if reason

          new(values)
        rescue JSON::ParserError
          raise CheckpointError.new("not JSON", position: position)
        end

        # Checkpoint lines or Checkpoints, as Checkpoints; nil means the configured anchor's.
        def self.read_all(given)
          given = Reeve.config.ledger_anchor&.checkpoints || [] if given.nil?
          given.each_with_index.map do |checkpoint, index|
            checkpoint.is_a?(Checkpoint) ? checkpoint : parse(checkpoint, position: index + 1)
          end
        end

        # Where verification walks from (FR-015): nil for the genesis, :latest for the highest
        # of `checkpoints`, or a Checkpoint given as itself.
        def self.start(from, checkpoints)
          return from if from.nil? || from.is_a?(Checkpoint)
          unless from == :latest
            raise ArgumentError,
                  "from: must be :latest or a Checkpoint, got #{from.inspect}"
          end

          checkpoints.max_by(&:head_sequence) ||
            raise(CheckpointError,
                  "FROM=latest needs a checkpoint to start from, and none was given")
        end

        def self.problem(values)
          return "not a JSON object" unless values.is_a?(Hash)

          shape_problem(values) || value_problem(values)
        end

        def self.shape_problem(values)
          missing = TYPES.keys - values.keys
          extra = values.keys - TYPES.keys
          return "missing #{missing.join(', ')}" if missing.any?
          return "unexpected #{extra.join(', ')}" if extra.any?

          "format #{values['format'].inspect} is not one this version reads (#{FORMAT})" unless
            values["format"] == FORMAT
        end

        def self.value_problem(values)
          wrong = TYPES.find { |field, types| types.none? { |type| values[field].is_a?(type) } }
          if wrong
            return "#{wrong[0]} is not #{wrong[1].first == Integer ? 'a whole number' : 'a string'}"
          end
          return "epoch and epoch_digest must both be set or both be null" if
            values["epoch"].nil? != values["epoch_digest"].nil?

          "head_sequence must be at least 1" unless values["head_sequence"].positive?
        end

        private_class_method :problem, :shape_problem, :value_problem

        def initialize(values)
          @values = values.dup.freeze
          freeze
        end

        # One line of JSON, keys sorted (contracts/checkpoint-v1.md).
        def to_line
          JSON.generate(@values.sort.to_h)
        end

        # :valid, :altered, or :key_not_configured when `keyring` lacks the key that signed it.
        def signed_by(keyring)
          secret = keyring.for(key_id)
          return :key_not_configured if secret.nil?

          Canonical.checkpoint_signature(secret, @values) == signature ? :valid : :altered
        end

        def as_json(*)
          { "head_sequence" => head_sequence, "made_at" => made_at }
        end
      end

      # What `bin/rails reeve:checkpoint_ledger` did (specs/004 data-model "Checkpoint result").
      #
      #   :made     — `checkpoint` was made; `published` says whether the anchor took it, and
      #               `error` why it did not, when one is configured
      #   :refused  — nothing made; `reason` is :no_key or :no_chain
      class CheckpointResult
        PREFIX = "reeve ledger checkpoint:"

        attr_reader :status, :reason, :checkpoint, :error

        def self.refused(reason)
          new(status: :refused, reason: reason)
        end

        # Makes a checkpoint on the ledger's own connection and hands it to `anchor`. The
        # reading happens under the head's lock (Head#checkpoint); publishing after it is
        # released, so a slow store never holds a writer (FR-009).
        def self.make!(entry_class:, anchor:, keyring: Keyring.from(Reeve.config))
          return refused(:no_key) unless keyring.signing?

          Schema.new(entry_class).require_columns!
          checkpoint = entry_class.connection_pool.with_connection do |connection|
            Head.new(connection: connection, entry_class: entry_class).checkpoint(keyring)
          end
          checkpoint ? publish(checkpoint, anchor) : refused(:no_chain)
        end

        # Hands the line to `anchor`, if there is one. A failing anchor is reported, not raised:
        # the checkpoint was made, and its line can still be stored by hand.
        def self.publish(checkpoint, anchor)
          return new(status: :made, checkpoint: checkpoint) if anchor.nil?

          anchor.publish(checkpoint.to_line)
          new(status: :made, checkpoint: checkpoint, published: true)
        rescue StandardError => e
          new(status: :made, checkpoint: checkpoint, error: "#{e.message} (#{e.class})")
        end

        def initialize(status:, reason: nil, checkpoint: nil, published: false, error: nil)
          @status = status
          @reason = reason
          @checkpoint = checkpoint
          @published = published
          @error = error
          freeze
        end

        def made? = status == :made
        def refused? = status == :refused
        def published? = @published
        def anchor_failed? = !error.nil?

        def to_s
          return "#{PREFIX} REFUSED — #{refusal}; nothing was made" if refused?

          [first_line, checkpoint.to_line].join("\n")
        end

        private

        def first_line
          "#{PREFIX} MADE — head ##{Report.number(checkpoint.head_sequence)}#{epoch_text}, key " \
            "#{checkpoint.key_id}; #{where}"
        end

        def epoch_text
          checkpoint.epoch.nil? ? "" : ", epoch #{checkpoint.epoch}"
        end

        def where
          return "published to the anchor" if published?
          return "the anchor failed (#{error}), store the line below yourself" if anchor_failed?

          "no anchor configured, store the line below yourself"
        end

        def refusal
          case reason
          when :no_key then "no ledger key configured (config.ledger_key)"
          else "the ledger has no chain yet; nothing to checkpoint"
          end
        end
      end
    end
  end
end
