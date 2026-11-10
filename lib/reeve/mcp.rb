# frozen_string_literal: true

require_relative "integrations"

begin
  require "mcp"
rescue LoadError => e
  raise Reeve::ConfigurationError,
        "reeve/mcp needs the mcp gem, which could not be loaded (#{e.message}). Add mcp to " \
        "your Gemfile, or use Reeve.invoke directly: the core needs no MCP server library."
end

Reeve::Integrations.require_version!("reeve/mcp", "mcp", MCP::VERSION, ">= 1.0", "< 2.0")

# fast-mcp ships lib/mcp/tool.rb at the path the SDK autoloads MCP::Tool from. If fast-mcp
# loaded first, Ruby considers that path loaded and MCP::Tool never appears.
begin
  MCP::Tool::Response
rescue NameError
  raise Reeve::ConfigurationError,
        "reeve/mcp could not load MCP::Tool from the mcp gem. fast-mcp ships files at the " \
        "paths the official SDK autoloads (mcp/tool.rb, mcp/server.rb), so loading fast-mcp " \
        "first hides the SDK's classes. Run one MCP server library per process."
end

require_relative "integrations/mcp/context_builder"
require_relative "integrations/mcp/tool_extension"

Reeve::Integrations::Mcp.install!
