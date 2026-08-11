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
gem "fast-mcp"
gem "pundit"

# On the Ruby 3.0 floor the gem is pinned to the stack a Ruby 3.0 application actually
# runs — Rails 7.0 — which is the combination worth proving. It also avoids sqlite3 2.x,
# which needs a newer RubyGems than Ruby 3.0 ships with.
if RUBY_VERSION < "3.1"
  gem "activerecord", "~> 7.0.0"
  gem "activesupport", "~> 7.0.0"
  gem "sqlite3", "~> 1.7"
else
  gem "activerecord"
  gem "activesupport"
  gem "sqlite3"
end
