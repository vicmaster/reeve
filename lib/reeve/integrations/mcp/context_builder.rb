# frozen_string_literal: true

module Reeve
  module Integrations
    # The official MCP SDK bridge.
    module Mcp
      # Turns the SDK's server context into what a Reeve::Context is built from.
      #
      # The server context is whatever the host passed to `MCP::Server.new`, often the user
      # object, plus the verified access token. It goes to the resolver as request data,
      # which is never recorded. Only the client's own name and version are recorded, for
      # attribution (research R6, R7).
      module ContextBuilder
        module_function

        def attributes(server_context)
          client = client_for(server_context)

          {
            agent: { id: client[:name] || Context::UNKNOWN_AGENT_ID,
                     name: client.empty? ? nil : client.values.join(" ") },
            metadata: client.empty? ? {} : { client: client },
            request: { server_context: server_context, auth_info: auth_info_for(server_context) }
          }
        end

        def client_for(server_context)
          info = server_context.respond_to?(:client_info) ? server_context.client_info : nil
          return {} unless info.is_a?(Hash)

          name = info[:name] || info["name"]
          version = info[:version] || info["version"]
          return {} if name.nil? || name.to_s.strip.empty?

          { name: name.to_s, version: version&.to_s }.compact
        end

        def auth_info_for(server_context)
          return server_context.auth_info if server_context.respond_to?(:auth_info)

          server_context[:auth_info] if server_context.is_a?(Hash)
        end
      end
    end
  end
end
