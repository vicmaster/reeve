# frozen_string_literal: true

require "openssl"
require "reeve/audit"

# specs/002 T006 / FR-011, research R7: which key signs, which keys verify, and the name each
# goes by on a row.
RSpec.describe Reeve::Audit::Chain::Keyring do
  let(:current) { "c" * 32 }
  let(:retired) { "r" * 40 }

  def id_of(secret)
    OpenSSL::HMAC.hexdigest("SHA256", secret, "reeve-ledger-key-id")[0, 16]
  end

  it "fingerprints a key as the first 16 hex characters of HMAC-SHA256(key, label)" do
    expect(Reeve::LedgerKey.fingerprint(current)).to eq(id_of(current))
  end

  it "signs with the current key, under its fingerprint" do
    keyring = described_class.new(signing: current, retired: [retired])

    expect(keyring.signing_id).to eq(id_of(current))
    expect(keyring.signing_secret).to eq(current)
  end

  it "finds the current key and every retired key by fingerprint, and nothing else" do
    keyring = described_class.new(signing: current, retired: [retired])

    expect(keyring.for(id_of(current))).to eq(current)
    expect(keyring.for(id_of(retired))).to eq(retired)
    expect(keyring.for(id_of("x" * 32))).to be_nil
    expect(keyring.for(nil)).to be_nil
  end

  it "can verify without being able to sign, which is how an auditor holds keys" do
    keyring = described_class.new(signing: nil, retired: [current])

    expect(keyring).not_to be_signing
    expect(keyring.signing_id).to be_nil
    expect(keyring.for(id_of(current))).to eq(current)
    expect(keyring).not_to be_empty
  end

  it "is empty with no keys at all" do
    expect(described_class.new(signing: nil, retired: [])).to be_empty
  end

  it "builds itself from the configuration" do
    config = Reeve::Configuration.new
    config.ledger_key = current
    config.retired_ledger_keys = [retired]

    keyring = described_class.from(config)

    expect(keyring.signing_id).to eq(config.ledger_key_id)
    expect(keyring.for(id_of(retired))).to eq(retired)
  end

  it "never shows a secret when inspected" do
    keyring = described_class.new(signing: current, retired: [retired])

    expect(keyring.inspect).not_to include(current)
    expect(keyring.inspect).not_to include(retired)
    expect(keyring.inspect).to include(id_of(current))
  end
end
