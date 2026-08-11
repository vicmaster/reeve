# frozen_string_literal: true

# The smallest Rails application that can host an MCP server: ActiveRecord, no views, no
# assets, no eager loading. It exists so the quickstart can be executed rather than
# asserted about — a generator that produces an initializer no Rails app will boot is a
# generator that works only in its own specs.
require "rails"
require "active_record/railtie"
require "logger"

require "reeve"

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.consider_all_requests_local = true
    config.secret_key_base = "dummy-app-secret-key-base-for-specs-only"
    config.active_record.maintain_test_schema = false

    # Rails 7.0 only; the setting is gone in 7.1+. Without it the app boots with a
    # deprecation notice, and a dummy app that warns on boot is one nobody can assert
    # silence on. Version-gated rather than respond_to?-gated, because Rails config
    # objects accept any setting name and only complain when it is applied.
    if Rails::VERSION::STRING.start_with?("7.0")
      config.active_record.legacy_connection_handling = false
    end
  end
end
