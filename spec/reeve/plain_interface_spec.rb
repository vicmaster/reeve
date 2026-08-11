# frozen_string_literal: true

# FR-024: the plain interface gives the same guarantees with nothing else installed —
# no Rails, no ActiveRecord, no MCP server library, no test framework beyond the one
# running this file. Proven in a subprocess, because this suite has all of those loaded
# and asserting it in-process would prove nothing.
RSpec.describe "Reeve.invoke with nothing else installed" do
  def run(script)
    lib = File.expand_path("../../lib", __dir__)
    output = IO.popen(
      [RbConfig.ruby, "--disable-gems", "-I", lib, "-e", script, { err: %i[child out] }], &:read
    )
    [output, $CHILD_STATUS.success?]
  end

  # Plain Ruby records and a plain policy object: the whole stack, without a database.
  PRELUDE = <<~RUBY
    require "reeve"

    Record = Struct.new(:id, :owner_id)

    class RecordPolicy
      def self.authorize(principal, _action, record)
        return false if principal.nil?
        record.nil? || record.owner_id == principal
      end

      def self.scope(principal, relation)
        relation.select { |record| record.owner_id == principal }
      end
    end

    class Ledger
      attr_reader :entries
      def initialize = @entries = []
      def record(attributes) = @entries << attributes
    end

    LEDGER = Ledger.new
    ALL = [Record.new(1, "alice"), Record.new(2, "alice"), Record.new(3, "bob")]

    class SearchTool
      include Reeve::Guard
      guard_with RecordPolicy
      def call = ALL
    end

    Reeve.configure { |c| c.audit_recorder = LEDGER }
  RUBY

  it "scopes an array of plain objects to the acting principal" do
    output, ok = run(<<~RUBY)
      #{PRELUDE}
      mine = Reeve.invoke(tool: SearchTool, principal: "alice")
      puts mine.map(&:id).inspect
      puts Reeve.invoke(tool: SearchTool, principal: "bob").map(&:id).inspect
    RUBY

    expect(ok).to be(true), output
    expect(output).to include("[1, 2]")
    expect(output).to include("[3]")
  end

  it "denies with no principal, exactly as it does under Rails" do
    output, ok = run(<<~RUBY)
      #{PRELUDE}
      begin
        Reeve.invoke(tool: SearchTool, principal: nil)
        abort "expected a denial"
      rescue Reeve::DeniedError => e
        puts e.rule
      end
    RUBY

    expect(output.strip).to eq("no_principal")
    expect(ok).to be(true)
  end

  it "records one entry per invocation into whatever recorder the host supplied" do
    output, ok = run(<<~RUBY)
      #{PRELUDE}
      Reeve.invoke(tool: SearchTool, principal: "alice")
      begin
        Reeve.invoke(tool: SearchTool, principal: nil)
      rescue Reeve::DeniedError
        nil
      end
      puts LEDGER.entries.size
      puts LEDGER.entries.map { |e| [e[:outcome], e[:rule]].join(":" ) }.inspect
    RUBY

    expect(ok).to be(true), output
    expect(output).to include("2")
    expect(output).to include("allow:RecordPolicy#index")
    expect(output).to include("deny:no_principal")
  end

  it "runs the compliance checks with no test framework loaded" do
    output, ok = run(<<~RUBY)
      #{PRELUDE}
      require "reeve/testing"
      abort "a test framework was loaded" if Object.const_defined?(:RSpec) || Object.const_defined?(:Minitest)

      result = Reeve::Checks::CrossPrincipalLeak.new(
        tool: SearchTool, principals: %w[alice bob]
      ).call
      puts result.passed?
    RUBY

    expect(ok).to be(true), output
    expect(output.strip).to eq("true")
  end
end
