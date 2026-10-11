# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Input boundaries" do
  it "rejects malformed JSON and duplicate keys at every depth" do
    ['{"a":1,"a":2}', '{"a":{"b":1,"b":2}}', '{"a":NaN}', "{"].each do |source|
      expect { IODEF.parse(source) }.to raise_error(IODEF::ParseError)
    end
    expect(IODEF.validate("{").first.rule).to eq("json")
    expect { IODEF.parse(nil) }.to raise_error(IODEF::ParseError)
  end

  it "bounds input size, nesting, collection sizes and node count" do
    source = JSON.generate(minimal)
    expect { IODEF.parse(source, max_input_size: 5) }.to raise_error(IODEF::LimitError)
    expect { IODEF.parse(source, max_depth: 2) }.to raise_error(IODEF::LimitError)
    expect { IODEF::Document.new(minimal, max_collection_size: 1) }.to raise_error(IODEF::LimitError)
    expect { IODEF::Document.new(minimal, max_nodes: 5) }.to raise_error(IODEF::LimitError)
    doc = IODEF::Document.new(minimal, max_input_size: source.bytesize - 1)
    expect { doc.to_json }.to raise_error(IODEF::LimitError)
  end

  it "enforces hard limits even in lenient mode" do
    source = JSON.generate(minimal)
    expect { IODEF.parse(source, strict: false, max_depth: 1) }.to raise_error(IODEF::LimitError)
    expect { IODEF.validate(minimal, max_depth: 1) }.to raise_error(IODEF::LimitError)
  end

  it "rejects cycles, invalid encodings, invalid keys, infinities and non-JSON objects" do
    recursive = minimal
    recursive["cycle"] = recursive
    expect { IODEF::Document.new(recursive) }.to raise_error(IODEF::ValidationError, /cyclic/)
    [Object.new, Float::NAN, Float::INFINITY, "\xff".b].each do |value|
      expect { IODEF::Document.new(minimal.merge("extension" => value)) }.to raise_error(IODEF::ValidationError)
    end
    expect { IODEF::Document.new(minimal.merge(1 => "x")) }.to raise_error(IODEF::ValidationError)
    expect { IODEF::Document.new(minimal.merge(version: "2.0")) }.to raise_error(IODEF::ValidationError, /duplicate/)
  end

  it "bounds decoded binary lengths and never interpolates incident data into diagnostics" do
    value = { "X509Data" => ["secret"].pack("m0") }
    expect { IODEF::Validator.new(max_binary_size: 1).validate(value, type: "Certificate") }.to raise_error(IODEF::LimitError)
    %w[file bytes].each do |dtype|
      data = { "dtype" => dtype, "value" => dtype == "file" ? "AAAA" : "000000" }
      expect { IODEF::Validator.new(max_binary_size: 1).validate(data, type: "Extension") }.to raise_error(IODEF::LimitError)
    end
    data = minimal
    data["Incident"][0]["purpose"] = "confidential incident information"
    expect(IODEF.validate(data).map(&:message).join).not_to include("confidential")
  end

  it "can inspect validation failures before correcting them" do
    doc = IODEF.parse('{"version":"2.0"}', validate: false)
    expect(doc.warnings).not_to be_empty
    expect { doc.to_json }.to raise_error(IODEF::ValidationError)
  end
end
