# frozen_string_literal: true

# The official SDK and fast-mcp in one process.
#
# fast-mcp ships lib/mcp/tool.rb and lib/mcp/server.rb, the same paths the SDK autoloads
# MCP::Tool and MCP::Server from. Once fast-mcp has loaded its copies, Ruby treats those
# paths as loaded and the SDK's constants never appear. A host runs one MCP library; this
# suite runs both, so it loads the SDK, constants and all, before fast-mcp can.
begin
  require "mcp"
  MCP.constants.each { |name| MCP.const_get(name) }
rescue LoadError
  nil # Specs that need the SDK skip themselves when it is absent.
end
