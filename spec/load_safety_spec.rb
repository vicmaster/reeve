# frozen_string_literal: true

# SC-008: `require "reeve"` must succeed in a bare Ruby process — no Rails, no
# ActiveRecord, no Pundit, no MCP server library. The core is loadable anywhere; the
# Rails-facing parts are opt-in.
#
# This runs in a subprocess on purpose: the rest of the suite may have loaded any of
# those libraries, and asserting in-process would prove nothing.
RSpec.describe "loading reeve" do
  def load_in_clean_process(script)
    lib = File.expand_path("../lib", __dir__)
    output = IO.popen(
      [RbConfig.ruby, "--disable-gems", "-I", lib, "-e", script, { err: %i[child out] }], &:read
    )
    [output, $CHILD_STATUS.success?]
  end

  it "loads with no ActiveRecord, Pundit or MCP server library present" do
    script = <<~RUBY
      require "reeve"
      loaded = %w[ActiveRecord ActiveSupport Pundit FastMcp MCP ActionMCP].select do |name|
        Object.const_defined?(name)
      end
      abort "unexpectedly loaded: \#{loaded.join(', ')}" unless loaded.empty?
      puts Reeve::VERSION
    RUBY

    output, ok = load_in_clean_process(script)

    expect(output).to include(Reeve::VERSION), "reeve failed to load bare:\n#{output}"
    expect(ok).to be(true)
  end

  it "exposes the kernel and denies a call without a principal, without any host library" do
    script = <<~RUBY
      require "reeve"
      context = Reeve::Context.new(tool_name: "anything")
      begin
        Reeve::Invocation.call(context) { [] }
        abort "expected a denial"
      rescue Reeve::DeniedError => e
        puts e.rule
      end
    RUBY

    output, ok = load_in_clean_process(script)

    expect(output.strip).to eq("no_principal")
    expect(ok).to be(true)
  end

  # Every file reeve pulls in must be its own or part of Ruby itself. The allowlist is
  # deliberately explicit: adding to it is a decision, not an accident.
  STDLIB_ALLOWLIST = %w[securerandom.rb English.rb random/formatter.rb].freeze

  it "requires nothing beyond its own files and a short list of standard library files" do
    script = <<~RUBY
      before = $LOADED_FEATURES.dup
      require "reeve"
      allowed = #{STDLIB_ALLOWLIST.inspect}
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
