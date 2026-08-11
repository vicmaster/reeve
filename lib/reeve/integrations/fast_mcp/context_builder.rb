# frozen_string_literal: true

module Reeve
  module Integrations
    # The fast-mcp bridge: the DSL on every tool, and the envelope around every call.
    module FastMcp
      # Turns what a fast-mcp tool instance knows about its request into the attributes
      # a Reeve::Context is built from.
      #
      # fast-mcp constructs a tool as `tool.new(headers: headers)` per request and calls
      # `call_with_schema_validation!` on it, so the transport's headers are the only
      # per-request context a tool has. They are passed through to the principal resolver
      # untouched: the header that identifies the human is the host's decision, not ours
      # (research R2, resolved against fast-mcp 1.6.0).
      module ContextBuilder
        # Checked in order. The first that answers names the client for attribution only.
        AGENT_HEADERS = %w[X-MCP-Client X-Client-Name User-Agent].freeze

        module_function

        def attributes(tool)
          headers = headers_for(tool)

          {
            agent: { id: agent_id(headers), name: headers["X-MCP-Client"] },
            metadata: { headers: headers }
          }
        end

        def headers_for(tool)
          headers = tool.respond_to?(:headers) ? tool.headers : nil
          headers.is_a?(Hash) ? headers : {}
        end

        # Attribution is not authorization: a client that names itself is recorded by that
        # name, and one that does not is recorded as unknown rather than refused.
        def agent_id(headers)
          AGENT_HEADERS.each do |header|
            value = headers[header] || headers[header.downcase]
            return value.to_s unless value.nil? || value.to_s.strip.empty?
          end

          Context::UNKNOWN_AGENT_ID
        end
      end
    end
  end
end
