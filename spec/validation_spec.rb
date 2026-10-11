# frozen_string_literal: true

require "spec_helper"

RSpec.describe IODEF::Validator do
  def validate_type(type, value)
    described_class.new.validate(value, type: type)
  end

  it "validates both complete RFC document examples" do
    files = Dir[File.expand_path("../tmp/rfc/fixtures/section-4.*.json", __dir__)]
    expect(files.size).to eq(2)
    files.each do |path|
      json = File.read(path)
      expect(IODEF.parse(json).to_h).to eq(JSON.parse(json))
      expect(JSON.parse(IODEF.parse(json).to_json)).to eq(JSON.parse(json))
    end
  end

  it "matches all assigned CBOR map keys against the downloaded reference" do
    cddl = File.read(File.expand_path("../tmp/rfc/fixtures/section-6-2.1.original.txt", __dir__))
    assignments = cddl.scan(/^iodef-([\w-]+) = (-?\d+)$/).to_h.transform_values(&:to_i)
    expect(IODEF::MAPKEYS).to eq(assignments)
  end

  IODEF::SCHEMA.each do |type, definition|
    definition.fetch("fields").each do |field, descriptor|
      it "rejects null in #{type}.#{field}" do
        issues = validate_type(type, { field => nil })
        expect(issues.any? { |issue| issue.pointer == "/#{field}" && issue.rule != "required" }).to be(true)
      end
      next unless descriptor.end_with?("!")

      it "requires #{type}.#{field}" do
        expect(validate_type(type, {}).map { |issue| [issue.pointer, issue.rule] }).to include(["/#{field}", "required"])
      end
    end
  end

  it "rejects objects in place of any modeled collection and empty present arrays" do
    IODEF::SCHEMA.each do |type, definition|
      definition.fetch("fields").each do |field, descriptor|
        next unless descriptor.include?("[]")

        [{}, []].each do |value|
          expect(validate_type(type, { field => value }).map(&:pointer)).to include("/#{field}")
        end
      end
    end
  end

  {
    "Extension" => { "value" => "secret", "dtype" => "string" },
    "SoftwareReference" => { "spec-name" => "cpe", "value" => "cpe:2.3:a:example:product:*:*:*:*:*:*:*:*" },
    "StructuredInformation" => { "SpecID" => "urn:ietf:params:xml:ns:mile:mmdef:1.2", "ContentID" => "model-1" },
    "Platform" => { "SpecID" => "private", "ext-SpecID" => "example.platform" },
    "Scoring" => { "SpecID" => "private", "ext-SpecID" => "example.scoring" },
    "Confidence" => { "rating" => "high" },
    "IndicatorReference" => { "euid-ref" => "external.example/indicator-1" }
  }.each do |type, value|
    it "accepts #{type} with its model semantics" do
      expect(validate_type(type, value)).to be_empty
    end
  end

  it "checks extension selectors and companion fields both ways" do
    expect(validate_type("Incident", { "purpose" => "ext-value" }).map(&:pointer)).to include("/ext-purpose")
    expect(validate_type("Incident", { "purpose" => "reporting", "ext-purpose" => "custom" }).map(&:pointer)).to include("/ext-purpose")
    expect(validate_type("Extension", { "value" => "x", "dtype" => "ext-value", "ext-dtype" => "vendor" })).to be_empty
    expect(validate_type("Extension", { "value" => "x", "dtype" => "ext-value", "ext-dtype" => "" }).map(&:rule)).to include("extension")
  end

  it "requires private enumeration names only when an ID is used" do
    data = minimal.merge("private-enum-id" => "registry-1")
    expect(IODEF.validate(data).map(&:pointer)).to include("/private-enum-name")
    data["private-enum-name"] = "team.example"
    expect(IODEF.validate(data)).to be_empty
  end

  it "requires data types for custom software references" do
    expect(validate_type("SoftwareReference", { "spec-name" => "custom" }).map(&:pointer)).to include("/dtype")
  end

  it "accepts only numeric confidence values with a numeric rating" do
    expect(validate_type("Confidence", { "rating" => "numeric" }).map(&:pointer)).to include("/value")
    expect(validate_type("Confidence", { "rating" => "numeric", "value" => 0.75 })).to be_empty
    expect(validate_type("Confidence", { "rating" => "high", "value" => 0.75 }).map(&:rule)).to include("confidence")
  end

  it "requires a defined course of action" do
    %w[HistoryItem Expectation].each do |type|
      expect(validate_type(type, { "action" => "defined-coa" }).map(&:pointer)).to include("/DefinedCOA")
    end
  end

  it "validates IP categories for DNS servers" do
    value = { "Server" => "ns.example", "Address" => [{ "value" => "example", "category" => "site-uri" }] }
    expect(validate_type("NameServers", value).map(&:pointer)).to include("/Address/0/category")
    value["Address"][0] = { "value" => "192.0.2.2", "category" => "ipv4-addr" }
    expect(validate_type("NameServers", value)).to be_empty
  end

  it "checks port and protocol wire ranges" do
    expect(validate_type("Service", { "Port" => 80 }).map(&:pointer)).to include("/ip-protocol")
    expect(validate_type("Service", { "Port" => 65_536, "ip-protocol" => 256 }).map(&:rule)).to include("range")
    expect(validate_type("Service", { "Port" => 80, "ip-protocol" => 6 })).to be_empty
  end

  it "validates application and email headers" do
    header = { "value" => "7", "dtype" => "integer" }
    expect(validate_type("Service", { "ApplicationHeaderField" => [header] }).map(&:pointer)).to include("/ApplicationHeaderField/0/name")
    expect(validate_type("EmailData", { "EmailHeaderField" => [header] }).map(&:pointer)).to include("/EmailHeaderField/0/dtype")
    header.merge!("name" => "Subject", "dtype" => "string")
    expect(validate_type("EmailData", { "EmailHeaderField" => [header] })).to be_empty
  end

  it "checks structured data alternatives" do
    value = { "SpecID" => "private", "ext-SpecID" => "vendor", "RawData" => ["AA=="], "Reference" => [{ "URL" => ["https://example.test"] }] }
    expect(validate_type("StructuredInformation", value).map(&:rule)).to include("at_most_one")
    value.delete("Reference")
    expect(validate_type("StructuredInformation", value)).to be_empty
  end

  it "checks required hash target and hashing software" do
    hash = { "DigestMethod" => "AA==", "DigestValue" => "AQ==" }
    expect(validate_type("HashData", { "scope" => "file-pe-section", "Hash" => [hash] }).map(&:pointer)).to include("/HashTargetID")
    expect(validate_type("HashData", { "scope" => "file-pe-iat", "Hash" => [hash] }).map(&:rule)).to include("hash")
    hash["Application"] = { "Description" => ["Hash tool"] }
    expect(validate_type("HashData", { "scope" => "file-pe-iat", "Hash" => [hash] })).to be_empty
  end

  it "requires a format for bulk file hashes" do
    value = { "type" => "file-hash", "BulkObservableList" => "ff" }
    expect(validate_type("BulkObservable", value).map(&:pointer)).to include("/BulkObservableFormat")
    value["BulkObservableFormat"] = { "AdditionalData" => [{ "dtype" => "string", "value" => "other" }] }
    expect(validate_type("BulkObservable", value).map(&:rule)).to include("required")
  end

  it "rejects empty expressions and multioperand negations" do
    expect(validate_type("IndicatorExpression", {}).map(&:rule)).to include("at_least_one")
    ref = { "euid-ref" => "external" }
    expect(validate_type("IndicatorExpression", { "operator" => "not", "IndicatorReference" => [ref, ref] }).map(&:rule)).to include("operator")
    expect(validate_type("IndicatorExpression", { "operator" => "not", "IndicatorReference" => [ref] })).to be_empty
  end

  it "checks unique observable identifiers and resolved references" do
    data = minimal
    data["Incident"][0]["Indicator"] = [{ "IndicatorID" => { "id" => "indicator1", "name" => "team.example", "version" => "1" }, "uid-ref" => "missing" }]
    expect(IODEF.validate(data).map(&:rule)).to include("reference")
    data["Incident"][0]["observable-id"] = "missing"
    expect(IODEF.validate(data)).to be_empty
    data["Incident"][0]["EventData"] = [{ "observable-id" => "missing", "Description" => ["x"] }]
    expect(IODEF.validate(data).map(&:rule)).to include("identifier")
  end

  { "byte" => ["AA==", "AAA="], "file" => ["AAA=", "!"], "bytes" => %w[AB01 XYZ], "frame" => %w[00ff 0],
    "boolean" => %w[true yes], "integer" => ["-13", "1.0"], "real" => ["-1.5e3", "NaN"],
    "date-time" => ["2026-01-01T00:00:00Z", "2026-02-30T00:00:00Z"], "ntpstamp" => ["2026-01-01T00:00:00Z", "1"],
    "portlist" => ["1,3-7", "9-1"], "url" => ["https://example.test", "a b"], "character" => %w[音 ab],
    "json" => ['{"a":1}', '{"a":1,"a":2}'] }.each do |dtype, (valid, invalid)|
    it "validates #{dtype} extension content" do
      expect(validate_type("Extension", { "dtype" => dtype, "value" => valid })).to be_empty
      expect(validate_type("Extension", { "dtype" => dtype, "value" => invalid }).map(&:rule)).to include("dtype")
    end
  end

  it "validates multilingual descriptions and preserves translations" do
    value = { "Description" => ["hello", { "value" => "日本語", "lang" => "ja", "translation-id" => "a" }] }
    expect(validate_type("Software", value)).to be_empty
    value["Description"][1]["lang"] = "bad language"
    expect(validate_type("Software", value).map(&:pointer)).to include("/Description/1/lang")
  end

  it "escapes pointers and limits diagnostics" do
    data = minimal
    data["sensitive/field~"] = Object.new
    expect(IODEF.validate(data).first.pointer).to eq("/sensitive~1field~0")
    expect(described_class.new(max_violations: 1).validate({}).size).to eq(1)
    expect { described_class.new(max_depth: 0) }.to raise_error(ArgumentError)
    expect { described_class.new(unknown: 1) }.to raise_error(ArgumentError)
  end
end

RSpec.describe "Reference model coverage" do
  it "covers every property in every downloaded CDDL object definition" do
    source = File.read(File.expand_path("../tmp/rfc/fixtures/iodef.cddl", __dir__))
    definitions = source.scan(/^(\w+)\s*=\s*\{(.*?)^\}/m).to_h
    aliases = { "Document" => "iodef", "Software" => "SoftwareType", "Extension" => "ExtensionType", "MLString" => "MLStringType",
                "StructuredInformation" => "STRUCTUREDINFO", "Digest" => "Hash" }
    IODEF::SCHEMA.each do |type, definition|
      next if type == "Impact"

      expected = definitions.fetch(aliases.fetch(type, type)).scan(/iodef-([\w-]+)\s*=>/).flatten.uniq
      expected -= %w[SystemImpact BusinessImpact TimeImpact MonetaryImpact IntendedImpact] if type == "Assessment"
      expected << "ext-scope" if type == "HashData"
      expect(definition.fetch("fields").keys.sort).to eq(expected.sort), "Incomplete property coverage for #{type}"
    end
  end
end
