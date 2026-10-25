# frozen_string_literal: true

module Reeve
  # Registers the ledger tasks (`bin/rails reeve:verify_ledger`, `reeve:rotate_ledger_key`,
  # `reeve:checkpoint_ledger`, `reeve:purge_ledger`, `reeve:verify_archive`), and does nothing else.
  #
  # Loaded by lib/reeve.rb only when Rails::Railtie is already defined, so `require "reeve"`
  # in a plain Ruby process still loads nothing beyond reeve's own files and its short stdlib
  # allowlist (spec/load_safety_spec.rb).
  class Railtie < ::Rails::Railtie
    rake_tasks do
      require "reeve/tasks"
      Reeve::Tasks.define
    end
  end
end
