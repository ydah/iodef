# frozen_string_literal: true

require "spec_helper"

RSpec.describe IODEF::Types do
  {
    "integer" => [13, 1.5], "number" => [0.5, Float::INFINITY], "positive" => [1, 0], "id" => %w[node_1 1node],
    "language" => %w[ja-JP ja_ja], "timezone" => ["+14:00", "+15:00"], "version" => ["2.0", "1.0"],
    "datetime" => ["2024-02-29T23:59:59.5+09:00", "2023-02-29T00:00:00Z"], "uri" => ["urn:example:thing", "not a uri"],
    "binary" => ["AP8=", "AP9="], "portlist" => ["1,80,8000-9000", "65536"], "string" => ["text", nil]
  }.each do |type, (valid, invalid)|
    it "checks #{type} primitives" do
      expect(described_class.valid?(type, valid)).to be_truthy
      expect(described_class.valid?(type, invalid)).to be_falsey
      expect(described_class.valid?(type, {})).to be_falsey
    end
  end

  it "validates each registry value and rejects unknown enumerations" do
    IODEF::ENUMS.each do |name, values|
      values.each { |value| expect(described_class.valid?(name, value)).to be(true) }
      expect(described_class.valid?(name, "unregistered")).to be(false)
    end
  end

  it "rejects malformed encodings and malformed URIs" do
    expect(described_class.string?("\xff".b)).to be(false)
    expect(described_class.uri?("http://[invalid")).to be(false)
    expect(described_class.uri?("https://example.test/%xx")).to be(false)
    expect(described_class.datetime?(nil)).to be(false)
    expect(described_class.datetime?("today")).to be(false)
    expect(described_class.datetime?("2026-01-01T25:00:00Z")).to be(false)
    expect(described_class.valid?("missing", "x")).to be(false)
  end
end
