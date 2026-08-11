# frozen_string_literal: true

module Reeve
  module Authorization
    # The envelope's `authorizer` collaborator: turns a guard declaration plus a principal
    # into a Decision, through whichever adapter the policy speaks.
    #
    # It deliberately does not rescue. The envelope converts a raising policy into
    # `policy_error` and fails closed; swallowing it here would hide which policy broke.
    class Authorizer
      def authorize(context:, guard:)
        adapter = Adapter.resolve(guard.policy)

        adapter.authorize(
          principal: context.principal,
          policy: guard.policy,
          action: guard.action,
          record: nil
        )
      end
    end
  end
end
