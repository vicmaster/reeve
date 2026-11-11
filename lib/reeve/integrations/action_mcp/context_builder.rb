# frozen_string_literal: true

module Reeve
  module Integrations
    # The ActionMCP bridge.
    module ActionMcp
      # Turns what an ActionMCP tool knows about its call into what a Reeve::Context is
      # built from.
      #
      # The session and the execution context go to the resolver as request data, which is
      # never recorded. Only the client's own name and version are recorded, for
      # attribution. Not the session id: on some transports it is enough to resume a
      # session, and the ledger is append-only (research R6, R7).
      module ContextBuilder
        module_function

        def attributes(tool)
          client = client_for(tool.session)

          {
            arguments: tool.attributes,
            agent: { id: client[:name] || Context::UNKNOWN_AGENT_ID,
                     name: client.empty? ? nil : client.values.join(" ") },
            metadata: client.empty? ? {} : { client: client },
            request: { session: tool.session, execution_context: tool.execution_context }
          }
        end

        def client_for(session)
          info = session.respond_to?(:client_info) ? session.client_info : nil
          return {} unless info.is_a?(Hash)

          name = info[:name] || info["name"]
          version = info[:version] || info["version"]
          return {} if name.nil? || name.to_s.strip.empty?

          { name: name.to_s, version: version&.to_s }.compact
        end
      end
    end
  end
end
