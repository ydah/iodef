# frozen_string_literal: true

require "spec_helper"
require "iodef/xml"

RSpec.describe "XML conversion" do
  def source(content, attributes = "")
    <<~XML
      <IODEF-Document xmlns="urn:ietf:params:xml:ns:iodef-2.0" version="2.00" #{attributes}>
        <Incident purpose="reporting">
          <IncidentID name="team.example">case-1</IncidentID>
          <GenerationTime>2026-01-01T00:00:00Z</GenerationTime>
          #{content}
          <Contact type="organization" role="creator"><ContactName>Response team</ContactName></Contact>
        </Incident>
      </IODEF-Document>
    XML
  end

  def incident(xml)
    IODEF.parse_xml(xml).to_h.fetch("Incident").first
  end

  it "writes valid XML version and schema child order independently of JSON order" do
    data = minimal
    item = data["Incident"].first
    item["AdditionalData"] = [{ "dtype" => "integer", "value" => "4" }]
    item["Description"] = ["Summary"]
    item["AlternativeID"] = { "IncidentID" => [{ "id" => "other", "name" => "partner.example" }] }
    item["RelatedActivity"] = [{ "Campaign" => [{ "CampaignID" => ["campaign"] }] }]
    item.replace(item.to_a.reverse.to_h)
    xml = IODEF::Document.new(data).to_xml
    expect(xml).to include('version="2.00"')
    expect(xml.index("<IncidentID")).to be < xml.index("<AlternativeID")
    expect(xml.index("<AlternativeID")).to be < xml.index("<RelatedActivity")
    expect(xml.index("<GenerationTime")).to be < xml.index("<Description")
    expect(xml.index("<Contact ")).to be < xml.index("<AdditionalData")
    data["version"] = "2.00"
    expect(IODEF.parse_xml(xml).to_h).to eq(data)
  end

  it "flattens systems, records and application headers and restores their wrappers" do
    xml = source(<<~XML)
      <EventData>
        <Flow><System category="source"><Node><Address category="ipv4-addr">192.0.2.9</Address></Node>
          <Service ip-protocol="6"><Port>0443</Port><ApplicationHeader>
            <ApplicationHeaderField dtype="string" name="Host">example.test</ApplicationHeaderField>
          </ApplicationHeader></Service>
        </System></Flow>
        <Flow><System category="target"><Node><Address category="ipv6-addr">2001:db8::1</Address></Node></System></Flow>
        <Record><RecordData><RecordItem dtype="string">first line</RecordItem></RecordData>
          <RecordData><RecordItem dtype="integer">21</RecordItem></RecordData></Record>
      </EventData>
    XML
    document = IODEF.parse_xml(xml)
    event = document.to_h["Incident"][0]["EventData"][0]
    expect(event["System"].size).to eq(2)
    expect(event["System"][0]["Service"][0]).to include("Port" => 443, "ApplicationHeaderField" => [{ "dtype" => "string", "name" => "Host", "value" => "example.test" }])
    expect(event["RecordData"].size).to eq(2)
    emitted = document.to_xml
    expect(emitted).to include("<Flow>", "<Record>", "<ApplicationHeader>")
    expect(IODEF.parse_xml(emitted).to_h).to eq(document.to_h)
  end

  it "maps impact choices and exact integer and floating point lexical values" do
    xml = source(<<~XML)
      <Assessment><SystemImpact/><BusinessImpact/><IntendedImpact type="unknown"/>
        <TimeImpact metric="elapsed">1.25e1</TimeImpact><MonetaryImpact currency="JPY">9007199254740993</MonetaryImpact>
        <Counter type="count" unit="event">12</Counter><Confidence rating="numeric">0.5</Confidence>
      </Assessment>
    XML
    data = incident(xml)["Assessment"][0]
    expect(data["Impact"][0]).to eq("SystemImpact" => { "type" => "unknown" })
    expect(data["Impact"][1]).to eq("BusinessImpact" => { "type" => "unknown" })
    expect(data["Impact"][3]["TimeImpact"]["value"]).to eq(12.5)
    expect(data["Impact"][4]["MonetaryImpact"]["value"]).to eq(9_007_199_254_740_993)
    expect(data["Confidence"]["value"]).to eq(0.5)
    expect(incident(IODEF.parse_xml(xml).to_xml)["Assessment"]).to eq([data])
  end

  it "flattens indicator containers and observable references without merging identifiers" do
    xml = source(<<~XML)
      <IndicatorData><Indicator><IndicatorID name="team.example" version="1"> indicator_one </IndicatorID>
        <Observable><Address observable-id="address_one" category="ipv4-addr">192.0.2.7</Address></Observable>
      </Indicator><Indicator><IndicatorID name="team.example" version="1">indicator_two</IndicatorID>
        <IndicatorExpression operator="and"><ObservableReference uid-ref="address_one"/>
          <IndicatorReference euid-ref="partner:indicator" version="2"/>
        </IndicatorExpression>
      </Indicator></IndicatorData>
    XML
    document = IODEF.parse_xml(xml)
    indicators = document.to_h["Incident"][0]["Indicator"]
    expect(indicators[0]["IndicatorID"]["id"]).to eq("indicator_one")
    expect(indicators[1]["IndicatorExpression"]["uid-ref"]).to eq(["address_one"])
    expect(IODEF.parse_xml(document.to_xml).to_h).to eq(document.to_h)
  end

  it "preserves finite floating point bits including negative zero" do
    random = Random.new(7970)
    numbers = [0.0, -0.0, Float::MIN, Float::MAX, *Array.new(128) { random.bytes(8).unpack1("G") }].select(&:finite?)
    data = minimal
    data["Incident"][0]["Assessment"] = [{ "Impact" => [{ "BusinessImpact" => { "type" => "unknown" } }],
                                          "Counter" => numbers.map { |number| { "type" => "count", "unit" => "event", "value" => number } } }]
    copied = incident(IODEF::Document.new(data).to_xml)["Assessment"][0]["Counter"].map { |counter| counter["value"] }
    expect(copied.pack("G*")).to eq(numbers.pack("G*"))
  end

  it "preserves inherited languages, explicit resets and translation identifiers" do
    xml = source('<Description>事象</Description><Description xml:lang="" translation-id="one">text</Description>', 'xml:lang="ja"')
    descriptions = incident(xml)["Description"]
    expect(descriptions).to eq([{ "value" => "事象", "lang" => "ja" }, { "value" => "text", "lang" => "", "translation-id" => "one" }])
    expect(incident(IODEF.parse_xml(xml).to_xml)["Description"]).to eq(descriptions)
    data = minimal.merge("lang" => "ja")
    data["Incident"][0]["Description"] = ["English", { "value" => "事象", "lang" => "ja" }]
    emitted = IODEF::Document.new(data).to_xml
    expect(emitted).to include('<Description xml:lang="en">English</Description>')
    expect(incident(emitted)["Description"]).to eq(data["Incident"][0]["Description"])
  end

  it "resolves arbitrary namespace prefixes, entities and CDATA" do
    xml = source('<Description>A &amp; B &lt;x&gt; &#x1F680; <![CDATA[&literal;]]></Description>')
    xml = xml.gsub(/<(\/?)([A-Za-z][A-Za-z-]*)/, '<\1i:\2').sub('xmlns="', 'xmlns:i="')
    expect(incident(xml)["Description"]).to eq(["A & B <x> 🚀 &literal;"])
  end

  it "maps reference namespaces, nameservers and registry values" do
    xml = source(<<~XML)
      <Method><Reference><e:ReferenceName xmlns:e="urn:ietf:params:xml:ns:iodef-enum-1.0" specIndex="1">
        <e:ID>item_one</e:ID></e:ReferenceName></Reference></Method>
      <EventData><Flow><System><Node><DomainData system-status="unknown" domain-status="unknown">
        <Name>example.test</Name><Nameservers><Server>ns.example.test</Server><Address category="ipv4-addr">192.0.2.1</Address></Nameservers>
      </DomainData></Node></System></Flow>
        <Record><RecordData><WindowsRegistryKeysModified><Key><KeyName>Software\\Example</KeyName><Value>enabled</Value></Key></WindowsRegistryKeysModified></RecordData></Record>
      </EventData>
    XML
    document = IODEF.parse_xml(xml)
    data = document.to_h["Incident"][0]
    expect(data["Method"][0]["Reference"][0]["ReferenceName"]).to eq("specIndex" => 1, "ID" => "item_one")
    expect(data["EventData"][0]["System"][0]["Node"]["DomainData"][0]["NameServers"][0]["Server"]).to eq("ns.example.test")
    expect(data["EventData"][0]["RecordData"][0]["WindowsRegistryKeysModified"][0]["Key"][0]["KeyValue"]).to eq("enabled")
    expect(IODEF.parse_xml(document.to_xml).to_h).to eq(document.to_h)
  end

  it "preserves extension fragments with namespace bindings and inherited language" do
    xml = source('<AdditionalData dtype="xml">lead<a:note a:kind="a:term">本文</a:note><!--detail--><?local data?>tail</AdditionalData>', 'xml:lang="ja" xmlns:a="urn:example:note"')
    document = IODEF.parse_xml(xml)
    value = document.to_h["Incident"][0]["AdditionalData"][0]["value"]
    expect(value).to include('xmlns:a="urn:example:note"', 'xml:lang="ja"', "lead", "<!--detail-->", "<?local data?>tail")
    expect(IODEF.parse_xml(document.to_xml).to_h).to eq(document.to_h)
  end

  it "keeps unqualified embedded elements out of the surrounding IODEF namespace" do
    data = minimal.merge("lang" => "ja")
    data["Incident"][0]["AdditionalData"] = [{ "dtype" => "xml", "value" => "<note/>" }]
    document = IODEF::Document.new(data)
    emitted = document.to_xml
    expect(emitted).to include('<note xmlns="" xml:lang="">')
    parsed = IODEF.parse_xml(emitted)
    expect(IODEF.parse_xml(parsed.to_xml).to_h).to eq(parsed.to_h)
  end

  it "maps SCI identifiers and namespace-complete XML RawData" do
    xml = source(<<~XML)
      <Method><s:Vulnerability xmlns:s="urn:ietf:params:xml:ns:iodef-sci-1.0" SpecID="private" ext-SpecID="urn:example:record">
        <s:RawData dtype="xml"><r:record xmlns:r="urn:example:record" key="issue">detail</r:record></s:RawData>
        <s:Platform SpecID="private" ext-SpecID="urn:example:platform" ContentID="system"/>
        <s:Scoring SpecID="private" ext-SpecID="urn:example:score" ContentID="high"/>
      </s:Vulnerability></Method>
    XML
    document = IODEF.parse_xml(xml)
    record = document.to_h["Incident"][0]["Method"][0]["Vulnerability"][0]
    expect(record["Platform"][0]["ContentID"]).to eq("system")
    expect(record["RawData"][0].unpack1("m0")).to include('xmlns:r="urn:example:record"', 'key="issue"')
    expect(IODEF.parse_xml(document.to_xml).to_h).to eq(document.to_h)
  end

  it "supports XML software references and normalizes binary lexical whitespace" do
    xml = source(<<~XML)
      <EventData><Record><RecordData><Application><SoftwareReference spec-name="custom" dtype="xml"><p:package xmlns:p="urn:example:package">one</p:package></SoftwareReference></Application>
        <RecordItem dtype="file">AP8=\n</RecordItem><RecordItem dtype="byte">fw==</RecordItem>
      </RecordData></Record></EventData>
    XML
    document = IODEF.parse_xml(xml)
    record = document.to_h["Incident"][0]["EventData"][0]["RecordData"][0]
    expect(record["RecordItem"].map { |item| item["value"] }).to eq(%w[AP8= fw==])
    expect(IODEF.parse_xml(document.to_xml).to_h).to eq(document.to_h)
  end

  it "materializes XML defaults needed by required JSON fields" do
    xml = source('<EventData><Flow><System><Node><Address>2001:db8::1</Address></Node></System></Flow></EventData>')
    expect(incident(xml)["EventData"][0]["System"][0]["Node"]["Address"][0]["category"]).to eq("ipv6-addr")
  end

  it "fails rather than discarding unknown, mixed or repeated singleton XML data" do
    content = ['<GenerationTime>2026-01-01T00:00:00Z</GenerationTime>', '<Unknown>value</Unknown>',
               '<Description unknown="value">text</Description>', '<Description><span>text</span></Description>',
               '<EventData>unmapped text<Description>known</Description></EventData>',
               '<EventData><Record restriction="private"><RecordData><RecordItem dtype="string">x</RecordItem></RecordData></Record></EventData>',
               '<EventData><Flow/></EventData>', '<EventData><Flow><Node/></Flow></EventData>',
               '<AdditionalData dtype="string"><extra/></AdditionalData>', '<IndicatorData restriction="private"/>',
               '<IndicatorData><Indicator><ObservableReference uid-ref="one" extra="data"/></Indicator></IndicatorData>',
               '<IndicatorData><Indicator><ObservableReference uid-ref="one">text</ObservableReference></Indicator></IndicatorData>',
               '<Indicator><ObservableReference uid-ref="one"/></Indicator>']
    content.each { |item| expect { IODEF.parse_xml(source(item), validate: false) }.to raise_error(IODEF::ConversionError) }
  end

  it "rejects lossy JSON properties inside impacts and nested objects" do
    data = minimal
    data["Incident"][0]["Assessment"] = [{ "Impact" => [{ "BusinessImpact" => { "type" => "unknown" }, "vendor" => "data" }] }]
    expect { IODEF::Document.new(data).to_xml }.to raise_error(IODEF::ConversionError)
    data["Incident"][0]["Assessment"][0]["Impact"][0].delete("vendor")
    data["Incident"][0]["Assessment"][0]["Impact"][0]["BusinessImpact"]["vendor"] = "data"
    expect { IODEF::Document.new(data).to_xml }.to raise_error(IODEF::ConversionError)
  end

  it "rejects cryptographic XML structures whose binary serialization is unspecified" do
    xml = source('<EventData><Record><RecordData><CertificateData><Certificate><ds:X509Data xmlns:ds="http://www.w3.org/2000/09/xmldsig#"><ds:X509Certificate>AA==</ds:X509Certificate></ds:X509Data></Certificate></CertificateData></RecordData></Record></EventData>')
    expect { IODEF.parse_xml(xml) }.to raise_error(IODEF::ConversionError, /cryptographic/)
    data = minimal
    data["Incident"][0]["EventData"] = [{ "RecordData" => [{ "CertificateData" => [{ "Certificate" => [{ "X509Data" => "AA==" }] }] }] }]
    expect { IODEF::Document.new(data).to_xml }.to raise_error(IODEF::ConversionError, /cryptographic/)
  end

  it "rejects ambiguous RawData metadata and non-XML or unsafe embedded data" do
    xml = source('<Method><s:AttackPattern xmlns:s="urn:ietf:params:xml:ns:iodef-sci-1.0" SpecID="private" ext-SpecID="urn:example"><s:RawData dtype="xml" meaning="unmapped"><entry/></s:RawData></s:AttackPattern></Method>')
    expect { IODEF.parse_xml(xml) }.to raise_error(IODEF::ConversionError)
    data = minimal
    data["Incident"][0]["Method"] = [{ "AttackPattern" => [{ "SpecID" => "private", "ext-SpecID" => "urn:example", "RawData" => ["AP8="] }] }]
    expect { IODEF::Document.new(data).to_xml }.to raise_error(IODEF::ConversionError)
    data["Incident"][0].delete("Method")
    ['<!DOCTYPE a><a/>', '<a>&unknown;</a>', '<a/>trailing</fragment><root/>'].each do |fragment|
      data["Incident"][0]["AdditionalData"] = [{ "dtype" => "xml", "value" => fragment }]
      expect { IODEF::Document.new(data).to_xml }.to raise_error(IODEF::ConversionError)
    end
  end

  it "rejects SCI forms absent from the interoperable XML subset" do
    %w[Reference Scoring].each do |field|
      child = field == "Reference" ? '<Reference><URL>urn:example:reference</URL></Reference>' : '<s:Scoring SpecID="private" ext-SpecID="urn:example:score" ContentID="high"/>'
      xml = source("<Method><s:AttackPattern xmlns:s=\"urn:ietf:params:xml:ns:iodef-sci-1.0\" SpecID=\"private\" ext-SpecID=\"urn:example\">#{child}</s:AttackPattern></Method>")
      expect { IODEF.parse_xml(xml) }.to raise_error(IODEF::ConversionError)
      data = minimal
      content = field == "Reference" ? { "URL" => ["urn:example:reference"] } : { "SpecID" => "private", "ext-SpecID" => "urn:example:score", "ContentID" => "high" }
      data["Incident"][0]["Method"] = [{ "AttackPattern" => [{ "SpecID" => "private", "ext-SpecID" => "urn:example", field => [content] }] }]
      expect { IODEF::Document.new(data).to_xml }.to raise_error(IODEF::ConversionError)
    end
  end

  it "bounds namespace context copies while sharing unchanged parent bindings" do
    namespaces = 20.times.map { |index| "xmlns:p#{index}=\"urn:example:#{index}\"" }.join(" ")
    unchanged = source("<Description>text</Description>" * 12, namespaces)
    expect(IODEF.parse_xml(unchanged, max_nodes: 150).incidents.first.description.to_a.size).to eq(12)
    rebound = source('<Description xmlns:x="urn:example:local">text</Description>' * 12, namespaces)
    expect { IODEF.parse_xml(rebound, max_nodes: 150) }.to raise_error(IODEF::LimitError, /namespace/)
    xml = source('<AdditionalData dtype="xml"><a:note xmlns:a="urn:inner"/><a:note/></AdditionalData>', 'xmlns:a="urn:outer"')
    value = incident(xml)["AdditionalData"][0]["value"]
    expect(value).to include('xmlns:a="urn:inner"', 'xmlns:a="urn:outer"')
  end

  it "rejects malformed integer and non-finite number lexical forms" do
    %w[1.5 1x +].each do |number|
      xml = source("<EventData><Flow><System><Node><Address category=\"ipv4-addr\" vlan-num=\"#{number}\">192.0.2.1</Address></Node></System></Flow></EventData>")
      expect { IODEF.parse_xml(xml, validate: false) }.to raise_error(IODEF::ConversionError)
    end
    %w[NaN INF 1e999 1x].each do |number|
      xml = source("<Assessment><TimeImpact metric=\"elapsed\">#{number}</TimeImpact></Assessment>")
      expect { IODEF.parse_xml(xml, validate: false) }.to raise_error(IODEF::ConversionError)
    end
  end

  it "enforces XML well-formedness beyond permissive pull-parser events" do
    ['<Description>]]></Description>', '<Description>&#9999999999999999999999999999999999999;</Description>',
     '<Description>&#xFFFFFFFFFFFFFFFFFFFFFFFF;</Description>', '<Description>&#x110000;</Description>'].each do |content|
      expect { IODEF.parse_xml(source(content)) }.to raise_error(IODEF::ParseError)
    end
    expect { IODEF.parse_xml(source("") + "<![CDATA[ ]]>") }.to raise_error(IODEF::ParseError)
    expect(incident(source("<Description>a\rb\r\nc</Description>"))["Description"]).to eq(["a\nb\nc"])
    expect(incident(source("<Description>&amp;notdeclared;</Description>"))["Description"]).to eq(["&notdeclared;"])
    ["\n<?xml version=\"1.0\"?>", '<!--first--><?xml version="1.0"?>'].each do |prolog|
      expect { IODEF.parse_xml(prolog + source("")) }.to raise_error(IODEF::ParseError)
    end
    expect { IODEF.parse_xml(source('<?XML invalid?>')) }.to raise_error(IODEF::ParseError)
    expect { IODEF.parse_xml(source('').sub('name="team.example"', 'name="<invalid"')) }.to raise_error(IODEF::ParseError)
  end
end
