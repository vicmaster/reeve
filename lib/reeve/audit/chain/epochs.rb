# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      # The key epochs, as a write sees them (specs/003 FR-001–FR-005).
      #
      # One instance per append or rotation, bound to the connection it runs on and used
      # only under the chain record's lock (Head), so finding a key's epoch and opening the
      # next one are a single step as far as any other writer can tell. The epoch record
      # commits or rolls back with the write that opened it.
      #
      # A key opens one epoch, ever. A process signing with a key whose epoch is not the
      # latest — one still on the old key during a rolling deploy — writes under that
      # earlier epoch: a straggler, legitimate, and verified by its own key.
      class Epochs
        def initialize(connection:)
          @connection = connection
        end

        # The number of the epoch `signer`'s key opened, opening the next one at `sequence`
        # if it has none.
        def for_signing!(signer, sequence:)
          number_for(signer.signing_id) || open!(signer, first_sequence: sequence)[:epoch]
        end

        def number_for(key_id)
          value = connection.select_value("SELECT epoch FROM #{EPOCHS_TABLE} " \
                                          "WHERE key_id = #{connection.quote(key_id)}")
          value.nil? ? nil : Integer(value)
        end

        # Every epoch, oldest first, as hashes with symbol keys.
        def all
          connection.select_all("SELECT epoch, key_id, first_sequence FROM #{EPOCHS_TABLE} " \
                                "ORDER BY epoch")
                    .map do |row|
                      { epoch: Integer(row["epoch"]), key_id: row["key_id"],
                        first_sequence: Integer(row["first_sequence"]) }
                    end
        end

        # Writes epoch `max + 1` (or 0) for `signer`'s key and returns it. Linked to the
        # latest epoch's digest, or to the genesis for epoch 0, so the chain must have
        # started.
        def open!(signer, first_sequence:)
          latest = connection.select_one("SELECT epoch, epoch_digest FROM #{EPOCHS_TABLE} " \
                                         "ORDER BY epoch DESC LIMIT 1")
          epoch = { epoch: latest ? Integer(latest["epoch"]) + 1 : 0, key_id: signer.signing_id,
                    first_sequence: first_sequence, opened_at: Time.now.utc.floor(6) }
          previous = latest ? latest["epoch_digest"] : genesis_digest
          digest = Canonical.epoch_digest(signer.signing_secret, epoch, previous_digest: previous)
          epoch.merge(epoch_digest: digest).tap { |values| insert(values) }
        end

        private

        attr_reader :connection

        def insert(values)
          quoted = values.values.map { |value| connection.quote(value) }
          connection.insert("INSERT INTO #{EPOCHS_TABLE} (#{values.keys.join(', ')}) " \
                            "VALUES (#{quoted.join(', ')})")
        end

        def genesis_digest
          connection.select_value("SELECT genesis_digest FROM #{TABLE} " \
                                  "WHERE name = #{connection.quote(ChainRecord::LEDGER)}")
        end
      end
    end
  end
end
