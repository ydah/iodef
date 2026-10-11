# frozen_string_literal: true

require "spec_helper"

RSpec.describe IODEF do
  it "validates and round trips an incident" do
    document = IODEF.parse(JSON.generate(minimal))
    expect(document.version).to eq("2.0")
    expect(document.incidents.first.incident_id).to eq("id" => "case-1", "name" => "team.example")
    expect(document.incidents.first.contacts.first.role).to eq("creator")
    expect(JSON.parse(document.to_json)).to eq(minimal)
  end

  it "reports a required field through a JSON pointer" do
    data = minimal
    data["Incident"][0].delete("GenerationTime")
    expect(IODEF.validate(data).map(&:pointer)).to include("/Incident/0/GenerationTime")
    expect { IODEF.parse(JSON.generate(data)) }.to raise_error(IODEF::ValidationError)
    document = IODEF.parse(JSON.generate(data), strict: false)
    expect(document.warnings).not_to be_empty
    expect { document.to_json }.to raise_error(IODEF::ValidationError)
  end
end
