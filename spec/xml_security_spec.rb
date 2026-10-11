# frozen_string_literal: true

require "spec_helper"
require "iodef/xml"

RSpec.describe "XML input boundaries" do
  let(:xml) do
    <<~XML
      <IODEF-Document xmlns="urn:ietf:params:xml:ns:iodef-2.0" version="2.00">
        <Incident purpose="reporting">
          <IncidentID name="team.example">case-1</IncidentID>
          <GenerationTime>2026-01-01T00:00:00Z</GenerationTime>
          <Contact role="creator" type="organization"><ContactName>Response team</ContactName></Contact>
        </Incident>
      </IODEF-Document>
    XML
  end

  it "rejects DTDs before expanding internal, external, or parameter entities" do
    declarations = [
      '<!DOCTYPE IODEF-Document>',
      '<!DOCTYPE IODEF-Document SYSTEM "https://example.invalid/confidential">',
      '<!DOCTYPE IODEF-Document [<!ENTITY secret SYSTEM "file:///confidential">]>',
      '<!DOCTYPE IODEF-Document [<!ENTITY % secret SYSTEM "file:///confidential">%secret;]>',
      '<!DOCTYPE IODEF-Document [<!ENTITY a "expansion"><!ENTITY b "&a;&a;&a;">]>'
    ]
    declarations.each do |declaration|
      expect { IODEF.parse_xml(declaration + xml, strict: false) }.to raise_error(IODEF::ParseError) do |error|
        expect(error.message).not_to include("confidential", "expansion")
      end
    end
  end

  it "accepts declaration-like text in CDATA without treating it as markup" do
    source = xml.sub("<Contact ", '<Description><![CDATA[<!DOCTYPE harmless>]]></Description><Contact ')
    expect(IODEF.parse_xml(source).incidents.first.description.text).to eq("<!DOCTYPE harmless>")
  end

  it "rejects malformed XML, multiple roots, undefined entities, and invalid encodings" do
    [nil, xml.delete_suffix("\n").delete_suffix("</IODEF-Document>"), xml + xml,
     xml + "private incident text", xml.sub("case-1", "&undefined;"),
     xml.sub("case-1", "&#0;"), xml.sub("case-1", "&#999999999999999999999;"),
     xml.sub("case-1", "&#xFFFFFFFFFFFFFFFFFFFF;"), xml.sub("case-1", "\xff".b)].each do |source|
      expect { IODEF.parse_xml(source) }.to raise_error(IODEF::ParseError) do |error|
        expect(error.message).not_to include("private incident text")
      end
    end
  end

  it "rejects XML declarations outside the prolog and illegal literal markup" do
    sources = [
      "<!-- leading comment --><?xml version=\"1.0\"?>" + xml,
      " <?xml version=\"1.0\"?>" + xml,
      xml.sub("<Contact ", "<?XML forbidden?><Contact "),
      xml.sub('name="team.example"', 'name="team<example"'),
      xml.sub("case-1", "text]]>"),
      xml + "<![CDATA[outside]]>"
    ]
    sources.each { |source| expect { IODEF.parse_xml(source) }.to raise_error(IODEF::ParseError) }
  end

  it "rejects duplicate attributes, undeclared prefixes, and namespace substitutions" do
    sources = [
      xml.sub('purpose="reporting"', 'purpose="reporting" purpose="traceback"'),
      xml.sub("<Incident ", "<unknown:Incident ").sub("</Incident>", "</unknown:Incident>"),
      xml.sub("urn:ietf:params:xml:ns:iodef-2.0", "https://example.invalid/other"),
      xml.sub('purpose="reporting"', 'xmlns:other="https://example.invalid/other" other:purpose="reporting"')
    ]
    sources.each { |source| expect { IODEF.parse_xml(source, strict: false) }.to raise_error(IODEF::Error) }
  end

  it "bounds bytes, nesting, nodes, and collection sizes before conversion" do
    expect { IODEF.parse_xml(xml, max_input_size: 40) }.to raise_error(IODEF::LimitError)
    expect { IODEF.parse_xml(xml, max_nodes: 3, strict: false) }.to raise_error(IODEF::LimitError)
    expect { IODEF.parse_xml(xml, max_collection_size: 1, strict: false) }.to raise_error(IODEF::LimitError)
    deep = '<IODEF-Document xmlns="urn:ietf:params:xml:ns:iodef-2.0">' + "<EventData>" * 40 + "</EventData>" * 40 + "</IODEF-Document>"
    expect { IODEF.parse_xml(deep, max_depth: 8, strict: false) }.to raise_error(IODEF::LimitError)
  end

  it "retains validation diagnostics in inspection mode and validates XML output" do
    invalid = xml.sub('purpose="reporting"', 'purpose="not-a-purpose"')
    document = IODEF.parse_xml(invalid, strict: false)
    expect(document.warnings.map(&:pointer)).to include("/Incident/0/purpose")
    expect { document.to_xml }.to raise_error(IODEF::ValidationError)
    expect(IODEF.parse_xml(invalid, validate: false).warnings).not_to be_empty
  end

  it "refuses unrepresentable JSON extensions and XML control characters" do
    document = IODEF::Document.new(minimal.merge("vendor-field" => { "private" => true }))
    expect { document.to_xml }.to raise_error(IODEF::ConversionError)
    data = minimal
    data["Incident"][0]["Description"] = ["value\u0000"]
    expect { IODEF::Document.new(data).to_xml }.to raise_error(IODEF::ConversionError)
  end

  it "bounds serialized output after XML escaping" do
    data = minimal
    data["Incident"][0]["Description"] = ["&" * 600]
    document = IODEF::Document.new(data, max_input_size: 1100)
    expect { document.to_xml }.to raise_error(IODEF::LimitError)
  end

  it "escapes text and attributes without losing carriage returns or markup" do
    data = minimal
    data["Incident"][0]["IncidentID"]["name"] = "team\twith\nwhitespace\rand & markup"
    data["Incident"][0]["Description"] = ["<not-a-tag> & text\r\nnext line"]
    document = IODEF::Document.new(data)
    copy = IODEF.parse_xml(document.to_xml)
    expect(copy.incidents.first.incident_id).to eq(data["Incident"][0]["IncidentID"])
    expect(copy.incidents.first.description.text).to eq(data["Incident"][0]["Description"].first)
  end
end
