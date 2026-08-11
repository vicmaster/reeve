# frozen_string_literal: true

require_relative "reeve/version"

# Reeve — per-record authorization and an append-only audit ledger for the MCP tools
# a Rails application exposes to AI agents.
#
# 0.0.1 is a placeholder release reserving the gem name. It has no functionality yet.
# See https://github.com/vicmaster/reeve for progress.
module Reeve
  class Error < StandardError; end
end
