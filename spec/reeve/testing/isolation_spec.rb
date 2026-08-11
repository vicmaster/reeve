# frozen_string_literal: true

# T048 / FR-020, FR-026. The testing kit runs with no MCP client, no network, no server
# process — and the checks run with neither RSpec nor Minitest loaded.
#
# In a subprocess on purpose, for the same reason as spec/load_safety_spec.rb: this very
# suite has RSpec, Minitest, ActiveRecord and Pundit loaded, so asserting in-process would
# prove nothing at all. `--disable-gems` means the subprocess cannot reach a gem even if
# something tried to require one.
RSpec.describe "the testing kit in isolation" do
  def load_in_clean_process(script)
    lib = File.expand_path("../../../lib", __dir__)
    output = IO.popen(
      [RbConfig.ruby, "--disable-gems", "-I", lib, "-e", script, { err: %i[child out] }], &:read
    )
    [output, $CHILD_STATUS.success?]
  end

  it "loads the checks with no test framework, no ActiveRecord and no MCP library" do
    script = <<~RUBY
      require "reeve/testing"
      loaded = %w[RSpec Minitest ActiveRecord ActiveSupport Pundit FastMcp MCP ActionMCP]
               .select { |name| Object.const_defined?(name) }
      abort "unexpectedly loaded: \#{loaded.join(', ')}" unless loaded.empty?
      abort "Checks missing" unless Reeve::Checks::ALL.size == 7
      puts "checks only"
    RUBY

    output, ok = load_in_clean_process(script)

    expect(output.strip).to eq("checks only"), "reeve/testing failed to load bare:\n#{output}"
    expect(ok).to be(true)
  end

  # The contract's own promise: a rake task, a CI script, a deploy gate. This is that
  # script, run for real.
  it "runs a check and reports a violation with neither RSpec nor Minitest present" do
    script = <<~RUBY
      require "reeve/testing"

      class Recorder
        def self.entries = (@entries ||= [])
        def self.record(attributes) = entries << attributes
      end

      class Ungoverned
        include Reeve::Guard
        def call = []
      end

      Reeve.config.audit_recorder = Recorder

      report = Reeve::Checks.run(
        Reeve::Checks::GuardDeclared, principals: [Object.new, Object.new],
        tools: [Ungoverned]
      )
      abort "expected a failure" if report.passed?
      puts report.failures.first.message
    RUBY

    output, ok = load_in_clean_process(script)

    expect(output.strip).to eq(
      "expected Ungoverned to declare a guard, but it has no guard_with declaration — " \
      "reeve denies every call to an unguarded tool"
    )
    expect(ok).to be(true)
  end

  # A tool actually invoked, denied, and recorded — all with no test framework, no
  # database and no network. This is the "boot-time assertion in staging" path.
  it "invokes a tool through the envelope with no framework and no database" do
    script = <<~RUBY
      require "reeve/testing"

      class Recorder
        def self.record(attributes) = attributes
      end

      class Ungoverned
        include Reeve::Guard
        def call = []
      end

      Reeve.config.audit_recorder = Recorder
      result = Reeve::Checks::PrincipalRequired.new(tool: Ungoverned).call
      abort "expected a pass, got: \#{result.message}" unless result.passed?
      puts result.details[:rule]
    RUBY

    output, ok = load_in_clean_process(script)

    expect(output.strip).to eq("no_principal")
    expect(ok).to be(true)
  end

  # The ledger-reading checks need ActiveRecord. Without it they fail loudly and say what
  # to do — they never report green on a guarantee they could not verify.
  it "fails, with an actionable reason, when a ledger-reading check has no ledger" do
    script = <<~RUBY
      require "reeve/testing"

      class Recorder
        def self.record(attributes) = attributes
      end

      class Ungoverned
        include Reeve::Guard
        def call = []
      end

      Reeve.config.audit_recorder = Recorder
      result = Reeve::Checks::AuditCoverage.new(tool: Ungoverned, principal: Object.new).call
      abort "a check with no ledger reported green" if result.passed?
      puts result.message
    RUBY

    output, ok = load_in_clean_process(script)

    expect(output).to include("audit coverage cannot be verified for Ungoverned")
    expect(output).to include("the audit ledger is not loaded")
    expect(ok).to be(true)
  end

  it "requires nothing beyond reeve's own files and the standard library" do
    script = <<~RUBY
      before = $LOADED_FEATURES.dup
      require "reeve/testing"
      allowed = %w[securerandom.rb English.rb random/formatter.rb]
      added = ($LOADED_FEATURES - before)
        .grep_v(%r{/lib/reeve})
        .reject { |path| allowed.any? { |suffix| path.end_with?(suffix) } }
      abort "unexpected requires: \#{added.join(', ')}" unless added.empty?
      puts "self and stdlib only"
    RUBY

    output, ok = load_in_clean_process(script)

    expect(output.strip).to eq("self and stdlib only")
    expect(ok).to be(true)
  end
end
