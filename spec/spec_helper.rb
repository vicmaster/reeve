# frozen_string_literal: true

# This repository's files are UTF-8 — the documents, the generator templates, and the
# output of the subprocesses the isolation specs shell out to, all of which contain em
# dashes. Ruby reads them in the default external encoding, which is US-ASCII under a
# POSIX/C locale, and a spec that reads one then dies on `invalid byte sequence` before
# asserting anything.
#
# That was not hypothetical: eleven examples across five files were inert whenever a file
# was run on its own, and passed in a full run only because some other file happened to
# set the encoding first. Declaring it here fixes them at the root and makes a single-file
# run behave identically to the suite, whatever locale the developer or CI has.
Encoding.default_external = Encoding::UTF_8

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
