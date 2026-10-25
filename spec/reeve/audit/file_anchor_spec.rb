# frozen_string_literal: true

require "tmpdir"
require "reeve/audit"

# specs/004 FR-006a, research R6: the one anchor reeve ships.
RSpec.describe Reeve::Audit::FileAnchor do
  around do |example|
    Dir.mktmpdir("reeve-anchor") do |dir|
      @path = File.join(dir, "ledger.checkpoints")
      example.run
    end
  end

  let(:anchor) { described_class.new(@path) }

  it "appends one line per checkpoint" do
    anchor.publish('{"a":1}')
    anchor.publish('{"b":2}')

    expect(File.read(@path)).to eq("{\"a\":1}\n{\"b\":2}\n")
  end

  it "never rewrites what the file already holds" do
    File.write(@path, "kept as it was\n\n")

    anchor.publish('{"a":1}')

    expect(File.read(@path)).to eq("kept as it was\n\n{\"a\":1}\n")
  end

  it "refuses a line with a line break in it, which would read back as two" do
    expect { anchor.publish("{}\n{}") }.to raise_error(ArgumentError, /one line/)
    expect(File.exist?(@path)).to be(false)
  end

  it "reads back every non-blank line, in order" do
    File.write(@path, "{\"a\":1}\n\n  \n{\"b\":2}\n")

    expect(anchor.checkpoints).to eq(['{"a":1}', '{"b":2}'])
  end

  it "reads an anchor that has never been published to as empty" do
    expect(anchor.checkpoints).to eq([])
  end

  it "keeps every line whole when processes publish at once" do
    lines = Array.new(4) { |n| "{\"writer\":#{n},\"pad\":\"#{'x' * 4096}\"}" }
    # exit! so a child runs none of the parent's exit hooks: RSpec's, or the spec database's.
    pids = lines.map do |line|
      fork do
        25.times { described_class.new(@path).publish(line) }
        exit!(0)
      end
    end
    pids.each { |pid| Process.wait(pid) }

    read = anchor.checkpoints
    expect(read.size).to eq(100)
    expect(read.tally.keys).to match_array(lines)
  end
end
