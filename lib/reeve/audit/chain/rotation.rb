# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # What `bin/rails reeve:rotate_ledger_key` did, or why it did nothing (specs/003 FR-006,
      # FR-009, contracts/key-rotation.md). A value, so a deploy script can act on it without
      # reading the text. Names keys by fingerprint only, never by value (FR-007).
      #
      #   :rotated  — opened `epoch` with the configured key, from `first_sequence`
      #   :current  — the configured key opened the latest epoch already; nothing written
      #   :refused  — nothing written; `reason` is :no_key, :key_reused or :outgoing_key_missing
      class Rotation
        PREFIX = "reeve ledger key:"

        FIELDS = %i[status reason epoch key_id first_sequence previous_epoch previous_key_id
                    warnings].freeze

        attr_reader(*FIELDS)

        # Run under the chain record's lock (Chain#rotate_key!). `epochs` writes; `keyring`
        # is this host's — the configured key and the retired ones.
        def self.decide(epochs, keyring, head_sequence:, accept_unverifiable:)
          all = epochs.all
          own = all.find { |epoch| epoch[:key_id] == keyring.signing_id }
          # `own` first: with no epochs at all, nil would equal the missing latest one.
          return current(all, keyring) if own && all.last.equal?(own)
          return refused(:key_reused, epoch: own[:epoch], key_id: own[:key_id]) if own

          open_next(epochs, keyring, all.last, head_sequence: head_sequence,
                                               accept_unverifiable: accept_unverifiable)
        end

        def self.refused(reason, **fields)
          new(status: :refused, reason: reason, **fields)
        end

        def self.open_next(epochs, keyring, latest, head_sequence:, accept_unverifiable:)
          lost = latest && keyring.for(latest[:key_id]).nil?
          return refused(:outgoing_key_missing, **previous(latest)) if lost && !accept_unverifiable

          opened = epochs.open!(keyring, first_sequence: head_sequence + 1)
          new(status: :rotated, epoch: opened[:epoch], key_id: opened[:key_id],
              first_sequence: opened[:first_sequence], **previous(latest),
              warnings: lost ? [unverifiable(latest)] : [])
        end

        def self.current(all, keyring)
          latest = all.last
          before = all[-2]
          lost = before && keyring.for(before[:key_id]).nil?
          new(status: :current, epoch: latest[:epoch], key_id: latest[:key_id],
              first_sequence: latest[:first_sequence], **previous(before),
              warnings: lost ? [unverifiable(before)] : [])
        end

        def self.previous(epoch)
          epoch ? { previous_epoch: epoch[:epoch], previous_key_id: epoch[:key_id] } : {}
        end

        def self.unverifiable(epoch)
          "epoch #{epoch[:epoch]}'s key #{epoch[:key_id]} is not configured on this host, so " \
            "its entries are unverifiable here"
        end

        private_class_method :open_next, :current, :previous, :unverifiable

        def initialize(status:, warnings: [], **fields)
          @status = status
          @warnings = warnings.freeze
          (FIELDS - %i[status warnings]).each do |name|
            instance_variable_set(:"@#{name}", fields[name])
          end
          freeze
        end

        def rotated? = status == :rotated
        def current? = status == :current
        def refused? = status == :refused

        def to_s
          [first_line, *warnings.map { |warning| "warning: #{warning}" }].join("\n")
        end

        private

        def first_line
          case status
          when :rotated then "#{PREFIX} ROTATED — #{rotated_text}"
          when :current
            "#{PREFIX} CURRENT — epoch #{epoch} already signs with the configured key " \
            "#{key_id}; nothing to do"
          else "#{PREFIX} REFUSED — #{refusal}; nothing was written"
          end
        end

        def rotated_text
          text = "epoch #{epoch} opened with key #{key_id} from sequence " \
                 "#{Report.number(first_sequence)}"
          return text if previous_epoch.nil?

          "#{text}; epoch #{previous_epoch} (key #{previous_key_id}) stays verifiable while " \
            "that key is in retired_ledger_keys"
        end

        def refusal
          case reason
          when :no_key then "no ledger key configured (config.ledger_key)"
          when :key_reused
            "the configured key #{key_id} already opened epoch #{epoch}; a key opens one " \
            "epoch only — configure a new key"
          else
            "epoch #{previous_epoch}'s key #{previous_key_id} is not configured on this host, " \
            "so its entries would become unverifiable here — add it to " \
            "config.retired_ledger_keys, or run with ACCEPT_UNVERIFIABLE=1 if that key is lost"
          end
        end
      end
    end
  end
end
