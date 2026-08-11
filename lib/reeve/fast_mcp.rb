# frozen_string_literal: true

require_relative "../reeve"

begin
  require "fast_mcp"
rescue LoadError => e
  raise Reeve::ConfigurationError,
        "reeve/fast_mcp needs the fast-mcp gem, which could not be loaded (#{e.message}). " \
        "Add fast-mcp to your Gemfile, or use Reeve.invoke directly — the core needs no " \
        "MCP server library."
end

require_relative "integrations/fast_mcp/context_builder"
require_relative "integrations/fast_mcp/tool_extension"

module Reeve
  # Adapters for the MCP server libraries reeve rides on. Each is opt-in, conditionally
  # loaded, and never a dependency of the core (Constitution IV).
  module Integrations
  end
end

Reeve::Integrations::FastMcp.install!
