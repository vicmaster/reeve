# frozen_string_literal: true

module Reeve
  module Audit
    class Chain
      module Retention
        # A retention record's digest (specs/005 data-model): an HMAC under the signing key over
        # the record's fields and the previous record's digest, or the genesis digest for purge
        # 0, so the records are a chain of their own. Canonical's form, with a tag of its own.
        module Digest
          TAG = "reeve-ledger-retention-v1"

          FIELDS = %w[
            purge_number through_sequence through_digest previous_through removed_chained
            removed_pre_chain archived archive_sha256 purged_at key_id
          ].freeze

          module_function

          def call(secret, record, previous_digest:)
            pairs = FIELDS.map { |field| [field, Canonical.value(record, field)] }
            Canonical.hmac(secret, TAG,
                           Canonical.dump([["previous_digest", previous_digest], *pairs]))
          end
        end
      end
    end
  end
end
