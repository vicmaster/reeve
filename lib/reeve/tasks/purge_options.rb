# frozen_string_literal: true

module Reeve
  module Tasks
    # The environment `bin/rails reeve:purge_ledger` reads (specs/005, contracts/retention.md
    # "Rake"), as keyword arguments for Reeve::Audit::Chain.purge!. Anything it does not accept
    # is an ArgumentError naming what it does.
    module PurgeOptions
      module_function

      def from(env)
        through = env.fetch("THROUGH", "")
        older = env.fetch("OLDER_THAN", "")
        {
          through: through.empty? ? nil : whole_number("THROUGH", through),
          older_than: older.empty? ? nil : days("OLDER_THAN", older),
          archive: env["ARCHIVE"].to_s.empty? ? nil : env["ARCHIVE"],
          no_archive: flag("NO_ARCHIVE", env), confirm: flag("CONFIRM", env)
        }.tap { |options| require_one_archive_choice!(options) }
      end

      def require_one_archive_choice!(options)
        return unless options[:archive] && options[:no_archive]

        raise ArgumentError, "give ARCHIVE=path or NO_ARCHIVE=1, not both"
      end

      def whole_number(name, raw)
        Integer(raw, 10).tap { |value| raise ArgumentError unless value.positive? }
      rescue ArgumentError
        raise ArgumentError,
              "#{name} must be a checkpoint's sequence (a whole number), got #{raw.inspect}"
      end

      def days(name, raw)
        match = /\A(\d+)d\z/.match(raw)
        unless match
          raise ArgumentError,
                "#{name} must be a number of days such as 365d, got #{raw.inspect}"
        end

        Integer(match[1], 10)
      end

      def flag(name, env)
        raw = env.fetch(name, "")
        return false if raw.empty?
        return true if raw == "1"

        raise ArgumentError, "#{name} must be 1 or unset, got #{raw.inspect}"
      end
    end
  end
end
