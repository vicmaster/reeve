# frozen_string_literal: true

module Reeve
  # What makes a ledger key acceptable, and the name a key goes by (specs/002, research R7).
  #
  # Core rather than under reeve/audit, because configuration validates keys at assignment
  # and configuration loads without ActiveRecord. Validation needs nothing beyond Ruby;
  # `openssl` is required only when a fingerprint is computed, so `require "reeve"` stays on
  # its short stdlib allowlist (spec/load_safety_spec.rb) and a host that never configures
  # a key never loads it.
  module LedgerKey
    # HMAC-SHA256 takes a key of any length, but one shorter than the hash's own output
    # weakens it. Bytes, not characters: that is what the HMAC sees.
    MINIMUM_BYTES = 32

    FINGERPRINT_LABEL = "reeve-ledger-key-id"
    FINGERPRINT_LENGTH = 16

    module_function

    # The identifier stored on each chained row in place of the key. Derived from the key
    # rather than chosen by the host, so an identifier can never be pinned to the wrong
    # secret, and a renamed key cannot orphan the history it signed. An HMAC output, so it
    # says nothing about the key it names.
    def fingerprint(secret)
      require "openssl"
      OpenSSL::HMAC.hexdigest("SHA256", secret, FINGERPRINT_LABEL)[0, FINGERPRINT_LENGTH]
    end

    # Raises ArgumentError naming the setting and the rule. Never the value: a key that is
    # too short is still a secret, and error messages end up in logs.
    def validate!(secret, setting)
      unless secret.is_a?(String)
        raise ArgumentError, "#{setting} must be a String of at least #{MINIMUM_BYTES} " \
                             "bytes, got a #{secret.class}"
      end
      if secret.strip.empty?
        raise ArgumentError, "#{setting} must not be blank; it must be at least " \
                             "#{MINIMUM_BYTES} bytes"
      end
      return secret if secret.bytesize >= MINIMUM_BYTES

      raise ArgumentError, "#{setting} must be at least #{MINIMUM_BYTES} bytes, got " \
                           "#{secret.bytesize}"
    end
  end
end
