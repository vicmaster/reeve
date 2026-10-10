# frozen_string_literal: true

# FR-025 / Constitution VI: every public entry point ships with a runnable example. A
# README example that no longer parses, or that names a method the gem removed, is worse
# than no example — it is a promise that fails silently.
#
# The compliance-gate block is executed for real by spec/reeve/testing/isolation_spec.rb;
# this file covers the rest by parsing every example and checking the API it names.
RSpec.describe "README examples" do
  # Read as UTF-8 explicitly. `File.read` uses the default external encoding, which is
  # US-ASCII under a POSIX locale — and the README has em dashes in it, so every example
  # below died on `invalid byte sequence` instead of checking anything.
  README = File.read(File.expand_path("../README.md", __dir__), encoding: "UTF-8")

  def ruby_blocks
    README.scan(/```ruby\n(.*?)```/m).flatten
  end

  it "shows at least one example per documented capability" do
    expect(ruby_blocks.size).to be >= 8
  end

  it "parses every Ruby example" do
    ruby_blocks.each_with_index do |block, index|
      expect { RubyVM::InstructionSequence.compile(block) }
        .not_to raise_error, "README Ruby block ##{index + 1} does not parse:\n#{block}"
    end
  end

  describe "the API the README promises" do
    it "documents entry points that exist" do
      expect(Reeve).to respond_to(:invoke, :configure, :config, :registry)
      expect(Reeve::Guard::ClassMethods.instance_methods).to include(:guard_with, :redact)
      expect(Reeve::Guard.instance_methods).to include(:scoped)
    end

    it "names configuration settings that exist" do
      settings = README.scan(/config\.(\w+)\s*=/).flatten.uniq

      expect(settings).not_to be_empty
      settings.each do |setting|
        expect(Reeve.config).to respond_to("#{setting}="), "README sets config.#{setting}"
      end
    end

    it "names audit query methods that exist" do
      require "reeve/audit"
      methods = README.scan(/Reeve::Audit::Query\s*\n?\s*\.(\w+)/).flatten.uniq

      expect(methods).not_to be_empty
      methods.each { |method| expect(Reeve::Audit::Query).to respond_to(method) }
    end

    it "names testing-kit entry points that exist" do
      # The front-ends are opt-in requires, exactly as the README's comments say.
      require "reeve/testing"
      require "reeve/minitest"

      expect(Reeve::Checks).to respond_to(:run_all)
      expect(Reeve::Testing).to respond_to(:compliance_principals)
      expect(defined?(Reeve::Testing::Assertions)).to be_truthy
      expect(defined?(Reeve::Testing::ComplianceAssertions)).to be_truthy
    end

    # specs/002 FR-017, Constitution VI: every public entry point of the ledger chain is
    # shown in the README, and each one shown exists.
    it "names ledger-chain entry points that exist" do
      require "reeve/audit"
      require "reeve/tasks"

      expect(README).to include("Reeve::Audit::Chain.verify", "bin/rails reeve:verify_ledger",
                                "config.ledger_key", "config.retired_ledger_keys", ".append!(row)")
      expect(Reeve::Audit::Chain).to respond_to(:verify)
      expect(Reeve::Audit::Chain.instance_method(:append!).arity).to eq(1)
      expect(Reeve::Audit::Chain::Verification.public_instance_methods)
        .to include(:status, :covered, :to_s)
      expect(Reeve::Tasks).to respond_to(:verify_ledger, :define)
    end

    it "states the chain's limits, not only its guarantees" do
      expect(README).to include("**Not detected**", "A leaked key", "prevents nothing")
    end

    it "states the platform floor the gemspec enforces" do
      expect(README).to include("Ruby 3.0+")
      expect(Gem::Specification.load("reeve.gemspec").required_ruby_version.to_s)
        .to include("3.0")
    end
  end
end
