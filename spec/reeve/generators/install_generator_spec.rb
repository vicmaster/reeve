# frozen_string_literal: true

require "support/optional/database"

rails_available = begin
  require "rails/generators"
  require "rails/generators/test_case"
  true
rescue LoadError
  false
end

require "generators/reeve/install/install_generator" if rails_available

RSpec.describe "reeve:install generator", if: rails_available do
  let(:destination) { File.join(Dir.tmpdir, "reeve-generator-#{Process.pid}") }

  def run_generator(args = [])
    FileUtils.rm_rf(destination)
    FileUtils.mkdir_p(destination)
    Reeve::Generators::InstallGenerator.start(args, destination_root: destination)
  end

  def read(path)
    File.read(File.join(destination, path))
  end

  def migration_path
    Dir[File.join(destination, "db/migrate/*_create_reeve_audit_entries.rb")].first
  end

  after { FileUtils.rm_rf(destination) }

  describe "the initializer" do
    before { run_generator }

    it "is created where a Rails application expects it" do
      expect(File).to exist(File.join(destination, "config/initializers/reeve.rb"))
    end

    # FR-021: the resolver is the one thing only the host can answer.
    it "leaves principal_resolver as a TODO rather than guessing" do
      initializer = read("config/initializers/reeve.rb")

      expect(initializer).to match(/TODO/)
      expect(initializer).to include("principal_resolver")
    end

    # FR-023: the choice is explicit at install time, with both options in view.
    it "writes unguarded_tools explicitly, showing both options" do
      initializer = read("config/initializers/reeve.rb")

      expect(initializer).to match(/config\.unguarded_tools\s*=\s*:deny/)
      expect(initializer).to include(":allow_with_warning")
    end

    it "says what happens before the resolver is filled in" do
      expect(read("config/initializers/reeve.rb")).to match(/no_principal/)
    end

    it "produces Ruby that parses" do
      expect { RubyVM::InstructionSequence.compile(read("config/initializers/reeve.rb")) }
        .not_to raise_error
    end

    it "produces an initializer that runs against the real Configuration" do
      # The strongest thing this spec can assert: every setting the template names is a
      # setting that exists, with a value the setter accepts. Rails.logger stands in for
      # the boot-time constant the initializer legitimately expects.
      logger = Class.new { def warn(message); end }.new
      stub_const("Rails", Module.new { def self.logger = nil })
      allow(Rails).to receive(:logger).and_return(logger)
      Reeve.reset_configuration!
      expect { eval(read("config/initializers/reeve.rb")) }.not_to raise_error # rubocop:disable Security/Eval
      expect(Reeve.config.unguarded_tools).to eq(:deny)
      expect(Reeve.config.logger).to eq(logger)
      expect(Reeve.config.audit_failure_mode).to eq(:fail)
      expect(Reeve.config.redact_arguments).to include(:password, :ssn)
    end
  end

  describe "the migration" do
    before { run_generator }

    it "is created with a timestamped name" do
      expect(migration_path).not_to be_nil
      expect(File.basename(migration_path)).to match(/\A\d{14}_create_reeve_audit_entries\.rb\z/)
    end

    it "applies cleanly and creates the ledger with its indexes" do
      load migration_path
      connection = ActiveRecord::Base.connection
      connection.drop_table(:reeve_audit_entries, if_exists: true)

      CreateReeveAuditEntries.new.migrate(:up)

      expect(connection.table_exists?(:reeve_audit_entries)).to be(true)
      expect(connection.columns(:reeve_audit_entries).map(&:name))
        .to include("invocation_id", "rule", "detail", "record_ids", "outcome")
      expect(connection.indexes(:reeve_audit_entries).map(&:columns)).to include(["invocation_id"])
    end

    it "rolls back cleanly" do
      load migration_path
      connection = ActiveRecord::Base.connection
      connection.drop_table(:reeve_audit_entries, if_exists: true)

      CreateReeveAuditEntries.new.migrate(:up)
      CreateReeveAuditEntries.new.migrate(:down)

      expect(connection.table_exists?(:reeve_audit_entries)).to be(false)
    end
  end

  describe "running it twice" do
    it "does not raise, and leaves one migration" do
      run_generator
      expect { Reeve::Generators::InstallGenerator.start([], destination_root: destination) }
        .not_to raise_error

      migrations = Dir[File.join(destination, "db/migrate/*_create_reeve_audit_entries.rb")]
      expect(migrations.size).to eq(1)
    end
  end
end
