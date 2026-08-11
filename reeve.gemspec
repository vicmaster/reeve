# frozen_string_literal: true

require_relative "lib/reeve/version"

Gem::Specification.new do |spec|
  spec.name    = "reeve"
  spec.version = Reeve::VERSION
  spec.authors = ["Victor Velazquez"]
  spec.email   = ["velazquezgaspar16@gmail.com"]

  spec.summary = "Per-record authorization and audit guardrails for Rails MCP tools"
  spec.description = <<~DESC
    Reeve makes it safe for a Rails application to expose MCP (Model Context Protocol)
    tools to AI agents. Authentication says who is at the door; Reeve decides what they
    may touch and remembers what they touched: declarative per-record authorization
    scoped to the human the agent acts for, an append-only audit ledger of every call,
    and a testing kit that turns both guarantees into CI assertions. Works alongside
    fast-mcp, ActionMCP, and the official mcp gem. Developed under the working name
    mcp-guardrails.
  DESC

  spec.homepage = "https://github.com/vicmaster/reeve"
  spec.license  = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    # Publishing this gem requires MFA on the owner's account. A guardrails library that
    # could be replaced by anyone holding a stolen API key would be arguing against
    # itself.
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir[
    "lib/**/*.rb",
    # Generator templates: without these `rails g reeve:install` has nothing to copy.
    "lib/**/*.tt",
    "README.md",
    "CHANGELOG.md",
    "LICENSE.txt"
  ]
  spec.require_paths = ["lib"]

  # No runtime dependencies, by design. Rails, Pundit, fast-mcp, RSpec and Minitest are
  # all detected at load and never required.
end
