# frozen_string_literal: true

require "spec_helper"
require "iodef/xml"
require "rexml/document"

RSpec.describe "RFC 7970 XML document examples" do
  let(:fixtures) { File.expand_path("../tmp/rfc/fixtures", __dir__) }

  def xml_example(section, original: false)
    suffix = original ? ".original.xml" : ".xml"
    File.read(File.join(fixtures, "rfc7970-section-#{section}#{suffix}"))
  end

  def json_example(section)
    JSON.parse(File.read(File.join(fixtures, "section-#{section}-2.1.json")))
  end

  %w[7.1 7.2].each do |section|
    it "validates and round trips the complete section #{section} XML example through JSON" do
      document = IODEF.parse_xml(xml_example(section))
      expect(document.warnings).to be_empty
      json_document = IODEF.parse(document.to_json)
      xml_document = IODEF.parse_xml(json_document.to_xml)
      expect(xml_document.to_h).to eq(document.to_h)
      expect(IODEF.parse(xml_document.to_json).to_h).to eq(document.to_h)
    end
  end

  it "maps the minimal example to the corresponding complete RFC 8727 JSON document" do
    actual = IODEF.parse_xml(xml_example("7.1")).to_h
    expected = json_example("4.1")
    expect(actual.fetch("version")).to eq("2.00")
    expect(actual.merge("version" => expected.fetch("version"))).to eq(expected)
  end

  it "maps campaign metadata and preserves all four XML domains and free-form text" do
    xml = xml_example("7.2")
    source = REXML::Document.new(xml)
    actual = IODEF.parse_xml(xml).to_h.fetch("Incident").fetch(0)
    expected = json_example("4.2").fetch("Incident").fetch(0)
    %w[purpose restriction IncidentID GenerationTime Contact Assessment].each do |field|
      expect(actual.fetch(field)).to eq(expected.fetch(field))
    end
    activity = actual.fetch("RelatedActivity").fetch(0)
    expected_activity = expected.fetch("RelatedActivity").fetch(0)
    expect(activity.fetch("Campaign")).to eq(expected_activity.fetch("Campaign"))
    actor = activity.fetch("ThreatActor").fetch(0)
    expected_actor = expected_activity.fetch("ThreatActor").fetch(0)
    expect(actor.fetch("Description")).to eq(expected_actor.fetch("Description"))
    expect(actor.fetch("ThreatActorID").map(&:strip)).to eq(expected_actor.fetch("ThreatActorID"))

    description = source.elements["//Incident/Description"].texts.map(&:value).join
    expect(actual.fetch("Description")).to eq([description])
    expect(description.split.join(" ")).to eq(expected.fetch("Description").fetch(0))

    indicator = actual.fetch("Indicator").fetch(0)
    expected_indicator = expected.fetch("Indicator").fetch(0)
    %w[IndicatorID Description StartTime].each do |field|
      expect(indicator.fetch(field)).to eq(expected_indicator.fetch(field))
    end
    bulk = indicator.fetch("Observable").fetch("BulkObservable")
    text = source.elements["//BulkObservableList"].texts.map(&:value).join
    expect(bulk.fetch("type")).to eq("domain-name")
    expect(bulk.fetch("BulkObservableList")).to eq(text)
    expect(text.split.length).to eq(4)
    expect(text.split.first).to eq(expected_indicator.dig("Observable", "BulkObservable", "BulkObservableList"))
  end

  it "retains the invalid printed campaign example and reports its unknown enumeration" do
    original = xml_example("7.2", original: true)
    expect(original).to include('<BulkObservable type="fqdn">')
    expect(xml_example("7.2")).to eq(original.sub('type="fqdn"', 'type="domain-name"'))
    expect { IODEF.parse_xml(original) }.to raise_error(IODEF::ValidationError)
    document = IODEF.parse_xml(original, strict: false)
    bulk = document.to_h.dig("Incident", 0, "Indicator", 0, "Observable", "BulkObservable")
    expect(bulk.fetch("type")).to eq("fqdn")
    expect(document.warnings.map(&:pointer)).to include("/Incident/0/Indicator/0/Observable/BulkObservable/type")
  end
end
