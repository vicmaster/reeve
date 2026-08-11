# frozen_string_literal: true

# T066: the success-criteria audit is only useful while it is true. A mapping document
# that points at spec files which have moved or been deleted is worse than none, because
# it reads as coverage.
RSpec.describe "the verification map" do
  VERIFICATION = File.expand_path("../../specs/001-guardrails-core/verification.md", __dir__)

  let(:document) { File.read(VERIFICATION) }

  it "exists where the plan says it does" do
    expect(File).to exist(VERIFICATION)
  end

  it "names a spec file for every success criterion" do
    rows = document.scan(/^\| (SC-\d{3}) \|.*?\| (.*?) \|/)

    expect(rows.map(&:first)).to eq((1..9).map { |n| format("SC-%03d", n) })
    rows.each do |id, proof|
      expect(proof).to match(%r{spec/}), "#{id} names no spec"
    end
  end

  it "points only at files that exist" do
    root = File.expand_path("../..", __dir__)
    referenced = document.scan(%r{`(spec/[\w/.*-]+?\.rb)`}).flatten.uniq

    expect(referenced.size).to be >= 15
    missing = referenced.reject { |path| File.exist?(File.join(root, path)) }
    expect(missing).to be_empty, "verification.md points at missing files: #{missing.join(', ')}"
  end

  it "keeps the known gaps section, so partial coverage stays visible" do
    expect(document).to include("Known gaps")
    expect(document).to include("Existence disclosure")
  end
end
