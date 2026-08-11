# frozen_string_literal: true

require_relative "support/fixtures"

# T052 / Constitution IV, FR-026. Two claims, both of which are only worth making if
# something fails when they stop being true:
#
#   1. neither test framework is a dependency of this gem;
#   2. the plain-Ruby path in the README actually runs.
RSpec.describe "the testing kit's framework neutrality" do
  let(:gemspec) { Gem::Specification.load(File.expand_path("../../../reeve.gemspec", __dir__)) }

  it "declares no runtime dependency at all" do
    expect(gemspec.runtime_dependencies).to be_empty
  end

  it "keeps RSpec and Minitest out of the gemspec entirely" do
    named = gemspec.dependencies.map(&:name)

    expect(named).not_to include("rspec", "minitest", "rspec-core", "minitest-reporters")
  end

  it "keeps both frameworks in the Gemfile, since the kit must be provable from either" do
    gemfile = File.read(File.expand_path("../../../Gemfile", __dir__))

    expect(gemfile).to match(/^gem "rspec"$/)
    expect(gemfile).to match(/^gem "minitest"$/)
  end

  it "ships every testing-kit file in the gem" do
    files = gemspec.files

    expect(files).to include(
      "lib/reeve/testing.rb", "lib/reeve/rspec.rb", "lib/reeve/minitest.rb",
      "lib/reeve/testing/checks.rb", "lib/reeve/testing/checks/cross_principal_leak.rb",
      "lib/reeve/testing/matchers.rb", "lib/reeve/testing/assertions.rb",
      "lib/reeve/testing/compliance_suite.rb", "lib/reeve/testing/compliance_assertions.rb"
    )
  end

  # FR-025: a documented example that has never been run is a documented guess.
  describe "the README's compliance gate", :reeve_fixtures do
    def capture_stderr
      original = $stderr
      buffer = StringIO.new
      $stderr = buffer
      yield
      buffer.string
    ensure
      $stderr = original
    end

    let(:snippet) do
      readme = File.read(File.expand_path("../../../README.md", __dir__))
      readme[/<!-- reeve:compliance-gate -->\n```ruby\n(.*?)```/m, 1]
    end

    it "is present and self-contained" do
      expect(snippet).to include("Reeve::Checks.run_all")
      expect(snippet).to include("abort report.to_s unless report.passed?")
    end

    it "aborts with the report body when a registered tool leaks" do
      aborted = nil
      binding_for_snippet = binding
      binding_for_snippet.local_variable_set(:alice, alice)
      binding_for_snippet.local_variable_set(:bob, bob)

      printed = capture_stderr do
        binding_for_snippet.eval(snippet, "README.md")
      rescue SystemExit
        aborted = true
      end

      expect(aborted).to be(true)
      expect(printed).to include("FAIL CrossPrincipalLeak")
    end

    it "runs to completion when every registered tool is compliant" do
      Reeve.reset_registry!
      ReeveFixtures::CompliantInvoiceTool.redact(:customer_ssn)
      ReeveFixtures::CompliantInvoiceTool.guard_with(ReeveFixtures::GoodInvoicePolicy)

      binding_for_snippet = binding
      binding_for_snippet.local_variable_set(:alice, alice)
      binding_for_snippet.local_variable_set(:bob, bob)

      expect { binding_for_snippet.eval(snippet, "README.md") }.not_to raise_error
    end
  end
end
