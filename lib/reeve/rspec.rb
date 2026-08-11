# frozen_string_literal: true

require_relative "testing"
require_relative "testing/matchers"
require_relative "testing/compliance_suite"

# The RSpec front-end's entry point.
#
#   # spec/spec_helper.rb
#   require "reeve/rspec"
#   RSpec.configure { |config| config.include Reeve::Testing::Matchers }
#
# RSpec is a development dependency of this gem and never a runtime one: requiring *this*
# file is what pulls it in, and nothing under lib/reeve/testing/checks does.
#
# The include is left to the host rather than done here. A gem that silently mixes methods
# into every example group in an application is a gem you cannot reason about, and the one
# line above is not a burden worth that.
