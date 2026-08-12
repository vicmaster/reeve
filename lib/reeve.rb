# frozen_string_literal: true

require_relative "reeve/version"
require_relative "reeve/errors"
require_relative "reeve/decision"
require_relative "reeve/configuration"
require_relative "reeve/context"
require_relative "reeve/scope_result"
require_relative "reeve/invocation"
require_relative "reeve/authorization"

# Reeve — per-record authorization and an append-only audit ledger for the MCP tools
# a Rails application exposes to AI agents.
#
# A tool declares the policy that governs it with `guard_with`; every invocation is
# authorized, scoped to what the principal may see, and recorded. See
# https://github.com/vicmaster/reeve.
module Reeve
end
