# frozen_string_literal: true

# The acceptance bar for the Minitest front-end: a stock `rails new` application — no
# RSpec anywhere — proves every guarantee. This file is run by a subprocess in
# spec/reeve/quickstart_spec.rb with `ruby -Itest`, so nothing RSpec is loaded when it
# executes. If RSpec ever creeps into the kit's load path, the first assertion fails.

require_relative "../config/application"
Rails.application.initialize!

ActiveRecord::Base.logger = nil
ActiveRecord::Migration.verbose = false

template_root = File.expand_path("../../../lib/generators/reeve/install/templates", __dir__)
Object.class_eval(File.read(File.join(template_root, "create_audit_entries.rb.tt")), "migration.rb")
CreateReeveAuditEntries.new.migrate(:up)

ActiveRecord::Schema.define do
  create_table(:users, force: true) { |t| t.string :name }
  create_table :invoices, force: true do |t|
    t.string  :number
    t.integer :user_id
    t.boolean :overdue, default: false
    t.integer :cents, default: 0
  end
end

require_relative "../app/models"

ALICE = User.create!(name: "Alice")
BOB   = User.create!(name: "Bob")
Invoice.create!(number: "AC-1", user_id: ALICE.id, overdue: true, cents: 1000)
Invoice.create!(number: "AC-2", user_id: BOB.id, cents: 2500)

Reeve.configure do |config|
  config.principal_resolver = ->(context) { User.find_by(id: context.metadata[:user_id]) }
  config.compliance_principals = -> { [ALICE, BOB] }
end
require "reeve/audit"
require_relative "../app/tools"

require "minitest/autorun"
require "reeve/minitest"

class ReeveComplianceTest < Minitest::Test
  include Reeve::Testing::Assertions
  include Reeve::Testing::ComplianceAssertions

  def test_no_rspec_is_loaded
    refute defined?(::RSpec), "RSpec was loaded; this bar is about a stock rails new app"
  end

  def test_a_guarded_tool_denies_a_stranger
    stranger = User.create!(name: "Stranger")

    assert_denies_access_for InvoiceSearchTool, stranger, query: "AC"
  end

  def test_a_guarded_tool_is_audited
    assert_audits_every_call InvoiceSearchTool
  end

  def test_a_leaky_tool_fails_the_assertion
    leaky_policy = Class.new do
      def self.name = "LeakyPolicy"
      def self.authorize(*) = true
      def self.scope(_principal, relation) = relation
    end
    Object.const_set(:LeakyTool, Class.new do
      include Reeve::Guard

      def call = Invoice.all
    end)
    LeakyTool.guard_with(leaky_policy)

    error = assert_raises(Minitest::Assertion) do
      assert_reeve_check Reeve::Checks::CrossPrincipalLeak.new(
        tool: LeakyTool, principals: [ALICE, BOB]
      )
    end
    assert_includes error.message, "belonging to another principal"
  ensure
    # The compliance suite walks the registry, so the fixture must not outlive its test.
    Reeve.registry.remove(LeakyTool)
    Object.send(:remove_const, :LeakyTool) if Object.const_defined?(:LeakyTool)
  end
end
