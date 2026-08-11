# frozen_string_literal: true

require "reeve"

# Only the always-on helpers load here. Anything under support/optional/ is required by
# the specs that need it — the ActiveRecord harness in particular must not be loaded for
# specs that prove the core works without it.
Dir[File.expand_path("support/*.rb", __dir__)].each { |file| require file }

RSpec.configure do |config|
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Configuration is process-wide; no example may leak into the next.
  config.before do
    Reeve.reset_configuration!
    Reeve.reset_registry!
  end
end
