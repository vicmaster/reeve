# frozen_string_literal: true

module Reeve
  # Registers `bin/rails reeve:verify_ledger`, and does nothing else.
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
