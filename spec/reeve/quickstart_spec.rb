# frozen_string_literal: true

rails_available = begin
  require "rails"
  true
rescue LoadError
  false
end

# SC-004/SC-005: the quickstart is executable, not aspirational. Both halves run in a
# subprocess against a booted Rails application — this suite has RSpec, ActiveRecord and
# a database connection already loaded, and asserting any of this in-process would prove
# something weaker than what a host actually does.
RSpec.describe "the quickstart", if: rails_available do
  def run(script)
    root = File.expand_path("../..", __dir__)
    IO.popen(
      [RbConfig.ruby, "-I", File.join(root, "lib"), script, { err: %i[child out] }],
      chdir: root, &:read
    )
  end

  it "runs end to end in a Rails application, step by step as written" do
    output = run("spec/dummy/quickstart.rb")

    expect(output).to include("QUICKSTART OK"), output
    expect(output).not_to include("FAILED")

    # Each line is one documented promise of quickstart.md.
    [
      "the ledger table exists",
      "a relation-returning tool returns only the principal's records",
      "an out-of-scope single record is denied without disclosing it",
      "an aggregate computed from scoped(...) is allowed and marked derived",
      "an undeclared tool is denied",
      "every call left exactly one entry, allowed and denied alike",
      "a redacted argument keeps its name and loses its value",
      "the compliance suite runs from plain Ruby and passes",
      "the kit catches a tool that leaks across principals"
    ].each { |promise| expect(output).to include("ok #{promise}") }
  end

  it "emits no warnings of its own while doing it" do
    # A DSL that warns during ordinary correct use teaches people to ignore its warnings.
    # Scoped to reeve's own output: the host framework's deprecations are real, but they
    # are not ours, and failing the build on them would make this spec noise.
    output = run("spec/dummy/quickstart.rb")

    expect(output).not_to match(/^reeve:/)
    expect(output).not_to match(/reeve.*(warning|deprecat)/i)
  end

  # The acceptance bar for the Minitest front-end, executed rather than argued.
  it "proves every guarantee from a stock Rails test suite, with no RSpec loaded" do
    output = run("spec/dummy/test/compliance_test.rb")

    expect(output).to match(/0 failures, 0 errors/), output
    expect(output).to match(/\d+ runs/)
  end
end
