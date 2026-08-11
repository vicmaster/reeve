# frozen_string_literal: true

module Reeve
  module Authorization
    # Chooses the adapter a policy speaks through, and refuses declarations no adapter
    # can serve — at declaration time, so the developer learns immediately rather than on
    # the first denial in production (Constitution VI).
    module Adapter
      BUILT_IN = { plain: Adapters::Plain, pundit: Adapters::Pundit }.freeze

      module_function

      def resolve(policy, setting = Reeve.config.policy_adapter)
        case setting
        when :plain  then Adapters::Plain.new
        when :pundit then Adapters::Pundit.new
        when :auto   then auto_resolve(policy)
        else setting # a host-supplied adapter object; Configuration validated its protocol
        end
      end

      def resolve_name(policy, setting = Reeve.config.policy_adapter)
        return setting unless setting == :auto

        Adapters::Pundit.supports?(policy) ? :pundit : :plain
      end

      # Raises unless some adapter can serve this policy. Called from `guard_with`.
      def validate!(policy, setting = Reeve.config.policy_adapter)
        return true if supported?(policy, setting)

        raise ConfigurationError, unsupported_message(policy, setting)
      end

      def supported?(policy, setting = Reeve.config.policy_adapter)
        case setting
        when :plain  then Adapters::Plain.supports?(policy)
        when :pundit then Adapters::Pundit.supports?(policy)
        when :auto   then Adapters::Pundit.supports?(policy) || Adapters::Plain.supports?(policy)
        else true # a custom adapter is trusted to know its own policies
        end
      end

      def auto_resolve(policy)
        Adapters::Pundit.supports?(policy) ? Adapters::Pundit.new : Adapters::Plain.new
      end

      def unsupported_message(policy, setting)
        described = policy.respond_to?(:name) && policy.name ? policy.name : policy.inspect
        missing = Adapters::Plain.missing_methods(policy).map do |method|
          "##{method}"
        end.join(" and ")

        "#{described} cannot be used as a reeve policy (policy_adapter is #{setting.inspect}). " \
          "A plain policy must respond to #{missing.empty? ? '#authorize and #scope' : missing}; " \
          "a Pundit policy must define a query method and a Scope class."
      end
    end
  end

  # Reopened to answer one question the adapter layer owns: which adapter a policy will
  # actually be served by. Kept here rather than in the kernel so configuration.rb stays
  # free of any knowledge of policies.
  class Configuration
    # Which adapter `:auto` actually chose. Documented in contracts/policy-adapter.md so
    # the choice is never a mystery, and so the compliance suite can assert on it.
    def resolved_policy_adapter(policy = nil)
      Authorization::Adapter.resolve_name(policy, policy_adapter)
    end
  end
end
