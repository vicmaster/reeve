# frozen_string_literal: true

module Reeve
  module Audit
    module Chain
      # The keys one chained write or one verification may use (specs/002 FR-011, R7).
      #
      # One key signs; any number verify. Rows name their key by fingerprint, so lookup is
      # by fingerprint too, and a key the ring does not hold is simply absent — the verifier
      # turns that into "unverifiable", never into "tampered".
      #
      #   Keyring.from(Reeve.config)                        # what the recorder signs with
      #   Keyring.new(signing: nil, retired: [auditor_key]) # verify-only, e.g. an auditor
      class Keyring
        def self.from(config)
          new(signing: config.ledger_key, retired: config.retired_ledger_keys)
        end

        def initialize(signing:, retired: [])
          @signing_secret = signing
          @by_id = {}
          [signing, *retired].compact.each do |secret|
            @by_id[LedgerKey.fingerprint(secret)] ||= secret
          end
          @by_id.freeze
          freeze
        end

        attr_reader :signing_secret

        def signing_id
          signing_secret && LedgerKey.fingerprint(signing_secret)
        end

        def signing?
          !signing_secret.nil?
        end

        def for(key_id)
          @by_id[key_id]
        end

        def empty?
          @by_id.empty?
        end

        def inspect
          "#<#{self.class.name} signing=#{signing_id.inspect} keys=#{@by_id.keys.inspect}>"
        end
      end
    end
  end
end
