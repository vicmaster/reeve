# frozen_string_literal: true

require "bigdecimal"
require "json"
require "openssl"

module Reeve
  module Audit
    module Chain
      # The exact text a digest is computed over (specs/002 FR-002, FR-003; research R1, R2
      # step 2; data-model "Canonical entry").
      #
      # Computed once when a row is written and again, from what the database returns,
      # when it is verified — so everything here exists to make those two readings produce
      # identical text:
      #
      # * object keys sorted at every depth, so a database that reorders JSON keys
      #   (PostgreSQL jsonb, MySQL JSON) changes nothing;
      # * one spelling per number, so `1.0e+20` written and `100000000000000000000` read
      #   back are the same number;
      # * times as integer microseconds since the epoch, so neither the time zone nor the
      #   driver's Time class matters;
      # * strings, booleans and nil typed, so "1" and 1 never digest alike.
      #
      # The field list is written out rather than read from the table — a check that
      # derives its expectation from the thing it checks checks nothing — and is keyed by
      # contract version, so a future column joins the digest for rows written under that
      # contract only. The tags keep an entry digest and a genesis digest from ever being
      # interchangeable, and let a future canonical form be told apart from this one.
      module Canonical
        ENTRY_TAG = "reeve-ledger-entry-v1"
        GENESIS_TAG = "reeve-ledger-genesis-v1"

        ENTRY_FIELDS = {
          3 => %w[
            chain_sequence chain_key_id contract_version
            invocation_id occurred_at agent_id agent_name principal_type principal_id
            tool_name arguments outcome rule detail record_type record_ids record_count
            truncated derived guard duration_ms metadata
          ].freeze
        }.freeze

        GENESIS_FIELDS = %w[genesis_at pre_chain_count pre_chain_unchained_count
                            genesis_key_id].freeze

        TIME_FIELDS = %w[occurred_at genesis_at].freeze

        module_function

        def entry_digest(secret, row, previous_digest:)
          hmac(secret, ENTRY_TAG, entry_message_body(row, previous_digest))
        end

        def genesis_digest(secret, genesis)
          pairs = GENESIS_FIELDS.map { |field| [field, value(genesis, field)] }
          hmac(secret, GENESIS_TAG, dump(pairs))
        end

        def entry_message_body(row, previous_digest)
          version = value(row, "contract_version")
          fields = ENTRY_FIELDS.fetch(version) do
            raise ArgumentError,
                  "there is no canonical field list for audit-entry contract " \
                  "#{version.inspect}; only contract " \
                  "#{ENTRY_FIELDS.keys.join(', ')} rows are chained"
          end

          pairs = fields.map { |field| [field, value(row, field)] }
          dump([["previous_digest", previous_digest], *pairs])
        end

        def microseconds(time)
          (time.to_r * 1_000_000).floor
        end

        def dump(value)
          case value
          when Array then "[#{value.map { |item| dump(item) }.join(',')}]"
          when Hash then object(value)
          else scalar(value)
          end
        end

        def scalar(value)
          case value
          when nil, true, false then value.nil? ? "null" : value.to_s
          when Integer, Float, BigDecimal then number(value)
          when String, Symbol then JSON.generate(value.to_s)
          else
            raise ArgumentError,
                  "#{value.class} has no canonical form; normalize it before it is digested"
          end
        end

        def object(hash)
          pairs = hash.map { |key, item| [key.to_s, item] }.sort_by(&:first)
          "{#{pairs.map { |key, item| "#{JSON.generate(key)}:#{dump(item)}" }.join(',')}}"
        end

        # The shortest exact decimal: no exponent, no trailing zeros, no "-0".
        def number(value)
          if value.is_a?(Float) && !value.finite?
            raise ArgumentError,
                  "a non-finite number has no canonical form; normalize it before it is digested"
          end

          decimal = value.is_a?(Float) ? BigDecimal(value.to_s) : BigDecimal(value)
          return "0" if decimal.zero?
          return decimal.to_i.to_s if decimal.frac.zero?

          decimal.to_s("F")
        end

        def value(row, field)
          raw = if row.is_a?(Hash)
                  row.key?(field) ? row[field] : row[field.to_sym]
                else
                  row[field]
                end
          TIME_FIELDS.include?(field) && !raw.nil? ? microseconds(raw) : raw
        end

        def hmac(secret, tag, body)
          OpenSSL::HMAC.hexdigest("SHA256", secret, "#{tag}\n#{body}")
        end
      end
    end
  end
end
