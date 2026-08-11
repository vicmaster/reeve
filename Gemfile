# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# All development-only. Reeve has no runtime dependencies by design: everything below is
# detected at load time and never required by the core.
gem "rake"
gem "rubocop"

# Both testing frameworks, because the testing kit must be provable from either one
# (Constitution III).
gem "minitest"
gem "rspec"

# The host-side libraries the adapters integrate with, exercised in specs only.
gem "activerecord"
gem "activesupport"
gem "fast-mcp"
gem "pundit"
gem "sqlite3"
