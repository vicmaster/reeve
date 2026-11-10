# frozen_string_literal: true

require_relative "integrations"

begin
  require "action_mcp"
rescue LoadError => e
  raise Reeve::ConfigurationError,
        "reeve/action_mcp needs the actionmcp gem, which could not be loaded (#{e.message}). " \
        "Add actionmcp to your Gemfile, or use Reeve.invoke directly: the core needs no MCP " \
        "server library."
end

# The adapter reaches into ActionMCP's internals, so it loads only on the versions it was
# verified against (FR-013).
Reeve::Integrations.require_version!("reeve/action_mcp", "actionmcp", ActionMCP::VERSION,
                                     ">= 0.200.0", "< 0.204")

require_relative "integrations/action_mcp/context_builder"
require_relative "integrations/action_mcp/tool_extension"

Reeve::Integrations::ActionMcp.install!
