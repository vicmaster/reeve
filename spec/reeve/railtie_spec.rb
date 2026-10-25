# frozen_string_literal: true

require "open3"

# specs/002 T043, T046: with Rails present, `require "reeve"` brings in a Railtie whose only
# job is to register the ledger tasks (`reeve:verify_ledger`, `reeve:rotate_ledger_key`,
# `reeve:checkpoint_ledger`);
# without Rails it brings in nothing (spec/load_safety_spec.rb). A clean process, through Bundler, because this suite has
# loaded reeve before Rails and an in-process check would prove the load order of the spec
# run rather than a host's.
RSpec.describe "the Railtie" do
  def run_in_clean_process(script)
    root = File.expand_path("../..", __dir__)
    # The bundle this suite runs under, so each CI job checks the Rails it installed.
    gemfile = ENV.fetch("BUNDLE_GEMFILE", File.join(root, "Gemfile"))
    Open3.capture2e({ "BUNDLE_GEMFILE" => gemfile },
                    RbConfig.ruby, "-rbundler/setup", "-I", File.join(root, "lib"), "-e", script,
                    chdir: root)
  end

  it "loads when Rails is present, and registers the three ledger tasks and nothing else" do
    output, status = run_in_clean_process(<<~RUBY)
      require "rails"
      require "rake"
      require "reeve"
      abort "no Railtie" unless Reeve.const_defined?(:Railtie, false)
      Rake.application = Rake::Application.new
      Reeve::Railtie.instance.send(:run_tasks_blocks, nil) # protected; Rails calls it the same way
      puts Rake::Task.tasks.map(&:name).grep(/reeve/).sort.join(",")
    RUBY

    expect(status).to be_success, output
    expect(output.strip.lines.last).to eq("reeve:checkpoint_ledger,reeve:rotate_ledger_key,reeve:verify_ledger")
  end
end
