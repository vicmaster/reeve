# frozen_string_literal: true

# The quickstart, executed. Every step below is one step of
# specs/001-guardrails-core/quickstart.md, in order, against a booted Rails application.
# Run by spec/reeve/quickstart_spec.rb in a subprocess; prints one line per assertion.

require_relative "config/application"

Rails.application.initialize!

ActiveRecord::Base.logger = nil
ActiveRecord::Migration.verbose = false

def step(label)
  result = yield
  puts "#{result ? 'ok' : 'FAILED'} #{label}"
  abort("failed: #{label}") unless result
end

# --- Step 1: install -------------------------------------------------------------------
# `bin/rails generate reeve:install` writes the initializer and the migration. The
# generator itself is spec'd separately; here we run the migration it produces and load
# the initializer template it writes, because that is what "installed" means.
require "generators/reeve/install/install_generator"

template_root = File.expand_path("../../lib/generators/reeve/install/templates", __dir__)
migration_source = File.read(File.join(template_root, "create_audit_entries.rb.tt"))
Object.class_eval(migration_source, "create_audit_entries.rb")
CreateReeveAuditEntries.new.migrate(:up)

step("the ledger table exists") do
  ActiveRecord::Base.connection.table_exists?(:reeve_audit_entries)
end

ActiveRecord::Schema.define do
  create_table(:users, force: true) { |t| t.string :name }
  create_table :invoices, force: true do |t|
    t.string  :number
    t.integer :user_id
    t.boolean :overdue, default: false
    t.integer :cents, default: 0
  end
end

require_relative "app/models"

alice = User.create!(name: "Alice")
bob   = User.create!(name: "Bob")
Invoice.create!(number: "AC-1", user_id: alice.id, overdue: true, cents: 1000)
Invoice.create!(number: "AC-2", user_id: alice.id, cents: 2500)
Invoice.create!(number: "AC-3", user_id: bob.id, overdue: true, cents: 9999)

# --- Step 2: say who the agent acts for ------------------------------------------------
# The initializer the generator writes, with the one TODO filled in — which is exactly
# what a host does after running it.
Reeve.configure do |config|
  config.principal_resolver = ->(context) { User.find_by(id: context.metadata[:user_id]) }
  config.unguarded_tools    = :deny
  config.redact_arguments   = %i[password token ssn]
  config.compliance_principals = -> { [User.first, User.last] }
end
require "reeve/audit"

step("reeve is configured and the ledger recorder resolved") do
  Reeve.config.audit_recorder == Reeve::Audit::Recorder
end

# --- Step 3: guard a tool --------------------------------------------------------------
require_relative "app/tools"

def invoke(tool, principal, **arguments)
  Reeve.invoke(tool: tool, arguments: arguments, principal: principal,
               agent: { id: "claude-desktop" })
end

step("a relation-returning tool returns only the principal's records") do
  invoke(InvoiceSearchTool, alice, query: "AC").map(&:number).sort == %w[AC-1 AC-2]
end

step("the same tool returns a different set to a different principal") do
  invoke(InvoiceSearchTool, bob, query: "AC").map(&:number) == %w[AC-3]
end

step("an out-of-scope single record is denied without disclosing it") do
  bobs = Invoice.find_by(number: "AC-3")
  invoke(InvoiceShowTool, alice, id: bobs.id)
  false
rescue Reeve::DeniedError => e
  e.rule == "out_of_scope_record" && !e.message.include?("AC-3")
end

step("an aggregate computed from scoped(...) is allowed and marked derived") do
  total = invoke(OverdueTotalTool, alice)
  entry = Reeve::Audit::Entry.order(:id).last
  total == 1000 && entry.derived? && entry.outcome == "allow"
end

step("an undeclared tool is denied") do
  invoke(LegacyExportTool, alice)
  false
rescue Reeve::DeniedError => e
  e.rule == "no_guard_declared"
end

# --- Step 4: the ledger ----------------------------------------------------------------
step("every call left exactly one entry, allowed and denied alike") do
  Reeve::Audit::Entry.count == 5 &&
    Reeve::Audit::Entry.pluck(:outcome).tally == { "allow" => 3, "deny" => 2 }
end

step("the ledger answers the question an incident asks") do
  rows = Reeve::Audit::Query.for_principal(alice).for_agent("claude-desktop")
                            .pluck(:tool_name, :outcome, :rule)
  rows.size == 4 && rows.all? { |row| !row[2].nil? }
end

step("a redacted argument keeps its name and loses its value") do
  invoke(InvoiceSearchTool, alice, query: "AC", customer_ssn: "123-45-6789")
  arguments = Reeve::Audit::Entry.order(:id).last.arguments

  arguments.key?("customer_ssn") && !arguments["customer_ssn"].to_s.include?("123-45")
end

# --- Step 5: prove it in CI ------------------------------------------------------------
require "reeve/testing"

step("the compliance suite runs from plain Ruby and passes") do
  report = Reeve::Checks.run_all(principals: [alice, bob])
  puts report unless report.passed?
  report.passed?
end

step("the kit catches a tool that leaks across principals") do
  Object.const_set(:LeakyPolicy, Class.new do
    def self.authorize(*) = true
    def self.scope(_principal, relation) = relation
  end)
  Object.const_set(:LeakyTool, Class.new do
    include Reeve::Guard

    guard_with LeakyPolicy
    def call = Invoice.all
  end)

  result = Reeve::Checks::CrossPrincipalLeak.new(tool: LeakyTool, principals: [alice, bob]).call
  !result.passed? && result.message.include?("belonging to another principal")
end

puts "QUICKSTART OK"
