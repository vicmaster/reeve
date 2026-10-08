# frozen_string_literal: true

module Reeve
  module Audit
    module Chain
      # Puts a row into the form the database will hand back, before it is written
      # (specs/002 FR-003, research R2 step 1).
      #
      # The digest is computed at write time and recomputed at verification from what the
      # database returns. The two only agree if nothing is left for the database to change,
      # so anything it would change is changed here first:
      #
      # * JSON values go through the column's own ActiveRecord type, encode and decode — the
      #   exact path a write takes. Symbol keys become strings, a Time inside the arguments
      #   becomes the string ActiveRecord stores, NaN becomes nil.
      # * `occurred_at` is floored to the precision the column keeps, so the database has
      #   no fraction to round (MySQL rounds; it does not truncate), and moved to UTC.
      #
      # What remains — JSON key order and how a number is spelled — is the database's to
      # change, and Canonical makes it irrelevant.
      #
      # It cannot recover a value the database alters for good: an integer beyond double
      # precision in a MySQL JSON column is stored rounded. That shows up as a false break,
      # never a false pass, and is documented.
      class Normalizer
        JSON_FIELDS = %i[arguments record_ids metadata].freeze
        TIME_FIELD = :occurred_at

        # Undeclared precision: MySQL's DATETIME is whole seconds, the others keep
        # microseconds.
        WHOLE_SECOND_ADAPTERS = /mysql|trilogy/i
        DEFAULT_PRECISION = 6

        def self.effective_precision(column, adapter_name)
          return column.precision unless column.precision.nil?

          adapter_name.to_s.match?(WHOLE_SECOND_ADAPTERS) ? 0 : DEFAULT_PRECISION
        end

        def initialize(entry_class)
          @entry_class = entry_class
        end

        # A new hash; the row passed in is not modified.
        def call(row)
          normalized = row.dup
          JSON_FIELDS.each do |field|
            next unless normalized.key?(field)

            normalized[field] = round_trip(field, normalized[field])
          end
          normalized[TIME_FIELD] = floor(normalized[TIME_FIELD]) if normalized[TIME_FIELD]
          normalized
        end

        private

        attr_reader :entry_class

        def round_trip(field, value)
          return nil if value.nil?

          type = json_types[field]
          type.deserialize(type.serialize(value))
        end

        def floor(time)
          time.to_time.getutc.floor(precision)
        end

        def json_types
          @json_types ||= JSON_FIELDS.to_h do |field|
            [field, entry_class.type_for_attribute(field.to_s)]
          end
        end

        def precision
          @precision ||= self.class.effective_precision(
            entry_class.columns_hash.fetch(TIME_FIELD.to_s), entry_class.connection.adapter_name
          )
        end
      end
    end
  end
end
