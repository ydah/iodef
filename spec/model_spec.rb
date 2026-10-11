# frozen_string_literal: true

require "spec_helper"

RSpec.describe IODEF::Document do
  it "builds a complete incident using typed views" do
    doc = described_class.build(lang: "en") do |document|
      document.add_incident(purpose: "reporting") do |incident|
        incident.incident_id = { id: "case-1", name: "team.example" }
        incident.generation_time = "2026-01-01T00:00:00Z"
        incident.description = ["An incident", { value: "事象", lang: "ja" }]
        incident.add_contact(role: "creator", type: "organization") { |contact| contact.contact_name = ["Response team"] }
      end
    end
    expect(doc.lang).to eq("en")
    expect(doc.incidents.first.description.text("ja")).to eq("事象")
    expect(doc.incidents.first.contacts.first.contact_name).to eq(["Response team"])
    expect(IODEF.parse(doc.to_json).to_h).to eq(doc.to_h)
  end

  it "uses mutable views and detached Hash exports" do
    input = minimal
    doc = described_class.new(input)
    input["version"] = "1.0"
    doc.incidents.first.contacts.first.role = "reporter"
    expect(doc["Incident"][0]["Contact"][0]["role"]).to eq("reporter")
    exported = doc.to_h
    exported["Incident"][0]["purpose"] = "invalid"
    expect(doc.incidents.first.purpose).to eq("reporting")
    doc[:extra] = ["value"]
    expect(doc.delete(:extra)).to eq(["value"])
    expect(doc.version).to eq("2.0")
  end

  it "provides typed assessments, indicators and event data" do
    doc = described_class.new(minimal)
    incident = doc.incidents.first
    incident.assessment = [{ "Impact" => [{ "BusinessImpact" => { "type" => "unknown" } }] }]
    incident.indicator = [{ "IndicatorID" => { "id" => "indicator1", "name" => "team.example", "version" => "1" },
                            "Observable" => { "AdditionalData" => [{ "dtype" => "string", "value" => "signal" }] } }]
    incident.event_data = [{ "Description" => ["Evidence"] }]
    expect(incident.assessments.first).to be_a(IODEF::Assessment)
    expect(incident.indicators.first).to be_a(IODEF::Indicator)
    expect(incident.event_data.first).to be_a(IODEF::EventData)
    expect(incident.indicators.first.description.to_a).to eq([])
    expect(IODEF.validate(doc)).to eq([])
    expect(IODEF::Incident.new({}, strict: false).assessments).to eq([])
    expect(IODEF::Incident.new({}, strict: false).contacts).to eq([])
    expect(IODEF::Incident.new({}, strict: false).indicators).to eq([])
  end

  it "rejects invalid mutations during generation" do
    doc = described_class.new(minimal)
    doc.incidents.first.purpose = "invalid"
    expect { doc.to_json }.to raise_error(IODEF::ValidationError) { |error| expect(error.pointer).to eq("/Incident/0/purpose") }
    expect { described_class.new([]) }.to raise_error(IODEF::ValidationError)
  end

  it "preserves unknown properties and number bits through randomized round trips" do
    random = Random.new(8427)
    200.times do
      data = minimal
      numbers = Array.new(4) { random.bytes(8).unpack1("G") }.select(&:finite?)
      data["vendor:extra"] = { "a/b~" => [random.rand(-(2**80)..(2**80)), *numbers, nil, true, false, "日本語\u0000"] }
      doc = described_class.new(data)
      parsed = IODEF.parse(doc.to_json).to_h
      expect(parsed).to eq(data)
      expected = data["vendor:extra"]["a/b~"].grep(Float).pack("G*")
      expect(parsed["vendor:extra"]["a/b~"].grep(Float).pack("G*")).to eq(expected)
    end
  end

  it "selects multilingual exact, prefix, default and first fallbacks" do
    text = IODEF::MultilingualText.new([{ "value" => "bonjour", "lang" => "fr" }, { "value" => "こんにちは", "lang" => "ja-JP" }, "default"])
    expect(text.text("FR")).to eq("bonjour")
    expect(text.text("ja")).to eq("こんにちは")
    expect(text.text("de")).to eq("default")
    expect(text.map { |item| item }).to eq(text.to_a)
    expect(IODEF::MultilingualText.new({ "value" => "x", "lang" => "en" }).text("de")).to eq("x")
    expect(IODEF::MultilingualText.new([]).text).to be_nil
  end
end
