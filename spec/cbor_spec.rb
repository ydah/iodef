# frozen_string_literal: true

require "spec_helper"
require "iodef/cbor"

RSpec.describe "CBOR" do
  it "uses assigned keys and tagged dates and round trips" do
    bytes = IODEF::Document.new(minimal).to_cbor
    decoded = IODEF::BinaryCBOR.decode(bytes)
    expect(decoded[-24]).to eq("2.0")
    expect(decoded[-19][0][10]).to eq(IODEF::BinaryCBOR::Tagged.new(0, "2026-01-01T00:00:00Z"))
    expect(IODEF.parse_cbor(bytes).to_h).to eq(minimal)
  end

  it "encodes bytes as binary with the expected base64 tag" do
    data = minimal
    data["Incident"][0]["EventData"] = [{ "RecordData" => [{ "CertificateData" => [{ "Certificate" => [{ "X509Data" => "AP9h" }] }] }] }]
    bytes = IODEF::Document.new(data).to_cbor
    expect(IODEF::BinaryCBOR.decode(bytes)[-19][0][15][0][89][0][145][0][154][0][155]).to eq(IODEF::BinaryCBOR::Tagged.new(22, "\x00\xffa".b))
    expect(IODEF.parse_cbor(bytes).to_h).to eq(data)
  end

  it "rejects duplicate map keys before information is lost" do
    expect { IODEF.parse_cbor([0xa2, 0x37, 0x61, 0x61, 0x37, 0x61, 0x62].pack("C*")) }.to raise_error(IODEF::ParseError, /duplicate/)
  end
end

RSpec.describe "CBOR boundaries" do
  def encoded(data = minimal)
    IODEF::Document.new(data).to_cbor
  end

  it "round trips both RFC JSON examples and binary extensions" do
    Dir[File.expand_path("../tmp/rfc/fixtures/section-4.*.json", __dir__)].each do |file|
      data = JSON.parse(File.read(file))
      expect(IODEF.parse_cbor(encoded(data)).to_h).to eq(data)
    end
    Dir[File.expand_path("../tmp/rfc/fixtures/section-4.*.cbor", __dir__)].each do |file|
      doc = IODEF.parse_cbor(File.binread(file))
      expect(IODEF.parse_cbor(doc.to_cbor).to_h).to eq(doc.to_h)
    end
    data = minimal
    data["AdditionalData"] = [{ "dtype" => "file", "value" => "AP8=" }, { "dtype" => "bytes", "value" => "00FF" }, { "dtype" => "string", "value" => "text" }]
    expect(IODEF.parse_cbor(encoded(data)).to_h).to eq(data)
    expect(IODEF::BinaryCBOR.decode(encoded(data))[-18][1][-17]).to eq(IODEF::BinaryCBOR::Tagged.new(23, "\x00\xff".b))
  end

  it "encodes real values without silent rounding" do
    data = minimal
    data["Incident"][0]["Assessment"] = [{ "Impact" => [{ "TimeImpact" => { "value" => 1.25, "metric" => "labor" } }] }]
    expect(encoded(data)).to include("\xfa\x3f\xa0\x00\x00".b)
    expect(IODEF.parse_cbor(encoded(data)).to_h).to eq(data)
    data["Incident"][0]["Assessment"][0]["Impact"][0]["TimeImpact"]["value"] = 0.1
    expect { encoded(data) }.to raise_error(IODEF::ConversionError, /float32/)
  end

  it "tags URLs and preserves unknown JSON values and large integers" do
    data = minimal
    data["Incident"][0]["RelatedActivity"] = [{ "URL" => ["https://example.test/incident"] }]
    data["vendor"] = { "number" => 2**100, "values" => [true, false, nil, -1, 0.01], "other" => { "name" => "value" } }
    expect(IODEF.parse_cbor(encoded(data)).to_h).to eq(data)
  end

  it "preserves URI spelling and negative bignums without backend coercion" do
    data = minimal
    data["Incident"][0]["RelatedActivity"] = [{ "URL" => ["HTTP://Example.test/Case%2f"] }]
    data["vendor:values"] = { "integers" => [2**100, -(2**100)], "unknown" => [nil, true, false, "日本語", 0.1] }
    expect(IODEF.parse_cbor(encoded(data)).to_h).to eq(data)
  end

  it "rejects unknown CBOR tags, bytes and unassigned keys without data loss" do
    [IODEF::BinaryCBOR::Tagged.new(33, "x"), IODEF::BinaryCBOR::Simple.new(16), "bytes".b].each do |value|
      data = IODEF::BinaryCBOR.decode(encoded)
      data["vendor"] = value
      expect { IODEF.parse_cbor(IODEF::BinaryCBOR.encode(data)) }.to raise_error(IODEF::ConversionError)
    end
    data = IODEF::BinaryCBOR.decode(encoded)
    data[999] = "unknown"
    expect { IODEF.parse_cbor(IODEF::BinaryCBOR.encode(data)) }.to raise_error(IODEF::ConversionError, /unassigned/)
    data = IODEF::BinaryCBOR.decode(encoded)
    data["version"] = "2.0"
    expect { IODEF.parse_cbor(IODEF::BinaryCBOR.encode(data)) }.to raise_error(IODEF::ParseError, /colliding/)
    expect { IODEF.parse_cbor(IODEF::BinaryCBOR.encode({ true => 1 })) }.to raise_error(IODEF::ConversionError)
  end

  it "accepts RFC example untagged dates while checking tagged payloads" do
    data = IODEF::BinaryCBOR.decode(encoded)
    data[-19][0][10] = "2026-01-01T00:00:00Z"
    expect(IODEF.parse_cbor(IODEF::BinaryCBOR.encode(data)).to_h).to eq(minimal)
    data[-19][0][10] = IODEF::BinaryCBOR::Tagged.new(0, "date".b)
    expect { IODEF.parse_cbor(IODEF::BinaryCBOR.encode(data)) }.to raise_error(IODEF::ConversionError)
  end

  it "accepts indefinite maps, arrays and text strings" do
    bytes = encoded
    expect(bytes.getbyte(0)).to eq(0xa2)
    indefinite_map = "\xbf".b + bytes.byteslice(1..) + "\xff".b
    expect(IODEF.parse_cbor(indefinite_map).to_h).to eq(minimal)
    indefinite_version = bytes.sub("\x63\x32\x2e\x30".b, "\x7f\x61\x32\x62\x2e\x30\xff".b)
    expect(IODEF.parse_cbor(indefinite_version).to_h).to eq(minimal)
    expect { IODEF.parse_cbor("\x9f\x01\xff".b) }.to raise_error(IODEF::ValidationError)
    expect { IODEF.parse_cbor("\x5f\x41\x00\xff".b) }.to raise_error(IODEF::ConversionError)
  end

  it "rejects malformed encodings, truncation and trailing items" do
    expect { IODEF.parse_cbor(nil) }.to raise_error(IODEF::ParseError)
    ["", "\xff", "\x1f", "\xdc", "\xdf", "\x7f\x41a\xff", "\x5f\x5f\xff\xff", "\xa1\x01", "\x18"].each do |bad|
      expect { IODEF.parse_cbor(bad.b) }.to raise_error(IODEF::ParseError)
    end
    expect { IODEF.parse_cbor(encoded + "\x00".b) }.to raise_error(IODEF::ParseError, /trailing/)
    expect { IODEF.parse_cbor("\xa2\x00\x01\x18\x00\x02".b) }.to raise_error(IODEF::ParseError, /duplicate/)
  end

  it "applies allocation limits during bounded decoding" do
    expect { IODEF.parse_cbor(encoded, max_input_size: 2) }.to raise_error(IODEF::LimitError)
    expect { IODEF.parse_cbor(encoded, max_nodes: 2) }.to raise_error(IODEF::LimitError)
    expect { IODEF.parse_cbor(encoded, max_depth: 2) }.to raise_error(IODEF::LimitError)
    expect { IODEF.parse_cbor(encoded, max_collection_size: 1) }.to raise_error(IODEF::LimitError)
    expect { IODEF.parse_cbor("\x9f\x01\x02\xff".b, max_collection_size: 1) }.to raise_error(IODEF::LimitError)
    expect { IODEF.parse_cbor("\x42\x00\x00".b, max_binary_size: 1) }.to raise_error(IODEF::LimitError)
    expect { IODEF.parse_cbor("\x5f\x42\x00\x00\xff".b, max_binary_size: 1) }.to raise_error(IODEF::LimitError)
    doc = IODEF::Document.new(minimal.merge("numbers" => Array.new(100, 2**60)), max_input_size: 1000)
    expect { doc.to_cbor }.to raise_error(IODEF::LimitError)
  end

  it "handles multibyte lengths" do
    data = minimal.merge("long" => "x" * 70_000)
    expect(IODEF.parse_cbor(encoded(data)).to_h).to eq(data)
  end
  it "fails random malformed CBOR with documented errors" do
    random = Random.new(8727)
    1000.times do
      bytes = random.bytes(random.rand(1..40))
      expect { IODEF.parse_cbor(bytes) }.to raise_error(IODEF::Error)
    end
  end
end
