# frozen_string_literal: true

require_relative "testing"
require_relative "testing/assertions"
require_relative "testing/compliance_assertions"

# The Minitest front-end's entry point.
#
#   # test/test_helper.rb
#   require "reeve/minitest"
#   Reeve::Testing.compliance_principals = -> { [users(:alice), users(:bob)] }
#
#   class ComplianceTest < ActiveSupport::TestCase
#     include Reeve::Testing::ComplianceAssertions
#   end
#
# Nothing here requires Minitest. The assertions call the `assert` their including test
# case already provides, so a stock `rails new` application proves every guarantee without
# adding a test framework — and Minitest stays a development-only dependency of this gem.
