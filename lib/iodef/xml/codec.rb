# frozen_string_literal: true

module Iodef
  class XMLCodec
    NS = "urn:ietf:params:xml:ns:iodef-2.0"
    SCI = "urn:ietf:params:xml:ns:iodef-sci-1.0"
    ENUM = "urn:ietf:params:xml:ns:iodef-enum-1.0"
    DS = "http://www.w3.org/2000/09/xmldsig#"
    XSI = "http://www.w3.org/2001/XMLSchema-instance"
    TEXT = { "IncidentID" => "id", "IndicatorID" => "id", "RegistryHandle" => "handle",
             "Address" => "value", "Counter" => "value", "TimeImpact" => "value", "MonetaryImpact" => "value",
             "Confidence" => "value", "RecordPattern" => "value", "MLString" => "value",
             "Extension" => "value", "SoftwareReference" => "value" }.freeze
    WRAPPERS = { "Incident" => { "Indicator" => "IndicatorData" }, "EventData" => { "System" => "Flow", "RecordData" => "Record" },
                 "Service" => { "ApplicationHeaderField" => "ApplicationHeader" },
                 "EmailData" => { "Signature" => "SignatureData" }, "File" => { "Signature" => "SignatureData" } }.freeze
    IMPACTS = %w[SystemImpact BusinessImpact TimeImpact MonetaryImpact IntendedImpact].freeze
    OPAQUE = %w[Signature X509Data DigestMethod CanonicalizationMethod].freeze
    STRUCTURED = %w[StructuredInformation Platform Scoring].freeze
    # XML has ordered children; JSON property insertion order carries no such meaning.
    ORDER = {
      "Document" => %w[Incident AdditionalData],
      "Incident" => %w[IncidentID AlternativeID RelatedActivity DetectTime StartTime EndTime RecoveryTime ReportTime GenerationTime Description Discovery Assessment Method Contact EventData Indicator History AdditionalData],
      "RelatedActivity" => %w[IncidentID URL ThreatActor Campaign IndicatorID Confidence Description AdditionalData],
      "ThreatActor" => %w[ThreatActorID URL Description AdditionalData], "Campaign" => %w[CampaignID URL Description AdditionalData],
      "Contact" => %w[ContactName ContactTitle Description RegistryHandle PostalAddress Email Telephone Timezone Contact AdditionalData],
      "PostalAddress" => %w[PAddress Description], "Email" => %w[EmailTo Description], "Telephone" => %w[TelephoneNumber Description],
      "DetectionPattern" => %w[Application Description DetectionConfiguration], "Method" => %w[Reference Description AttackPattern Vulnerability Weakness AdditionalData],
      "Reference" => %w[ReferenceName URL Description], "Assessment" => %w[IncidentCategory Impact Counter MitigatingFactor Cause Confidence AdditionalData],
      "HistoryItem" => %w[DateTime IncidentID Contact Description DefinedCOA AdditionalData],
      "EventData" => %w[Description DetectTime StartTime EndTime RecoveryTime ReportTime Contact Discovery Assessment Method System Expectation RecordData EventData AdditionalData],
      "Expectation" => %w[Description DefinedCOA StartTime EndTime Contact],
      "System" => %w[Node NodeRole Service OperatingSystem Counter AssetID Description AdditionalData],
      "Service" => %w[ServiceName Port Portlist ProtoType ProtoCode ProtoField ApplicationHeaderField EmailData Application],
      "ServiceName" => %w[IANAService URL Description],
      "RecordData" => %w[DateTime Description Application RecordPattern RecordItem URL FileData WindowsRegistryKeysModified CertificateData AdditionalData],
      "Certificate" => %w[X509Data Description], "File" => %w[FileName FileSize FileType URL HashData Signature AssociatedSoftware FileProperties],
      "FuzzyHash" => %w[FuzzyHashValue Application AdditionalData],
      "Indicator" => %w[IndicatorID AlternativeIndicatorID Description StartTime EndTime Confidence Contact Observable uid-ref IndicatorExpression IndicatorReference NodeRole AttackPhase Reference AdditionalData],
      "BulkObservable" => %w[BulkObservableFormat BulkObservableList AdditionalData], "BulkObservableFormat" => %w[Hash AdditionalData],
      "IndicatorExpression" => %w[IndicatorExpression Observable uid-ref IndicatorReference Confidence AdditionalData],
      "AttackPhase" => %w[AttackPhaseID URL Description AdditionalData], "Software" => %w[SoftwareReference URL Description],
      "StructuredInformation" => %w[RawData Reference Platform Scoring], "Platform" => %w[RawData Reference], "Scoring" => %w[RawData Reference]
    }.freeze

    def initialize(limits)
      @limits = limits
      @tree = XMLTree.new(limits)
    end

    def decode(root)
      expect_name(root, NS, "IODEF-Document")
      read_object(root, "Document")
    end

    def encode(data)
      writer = XMLTree::Writer.new(@limits)
      writer.append('<?xml version="1.0" encoding="UTF-8"?>')
      write_object(writer, "IODEF-Document", data, "Document", nil)
      output = writer.value
      # The same structural limits apply to output, including embedded XML fragments.
      @tree.parse(output)
      output
    end

    private

    def fields(type)
      SCHEMA.fetch(type).fetch("fields")
    end

    def descriptor(type, field)
      fields(type).fetch(field).delete_suffix("!")
    end

    def attribute?(type, field)
      return false if TEXT[type] == field || (%w[Indicator IndicatorExpression].include?(type) && field == "uid-ref")

      field.match?(/\A[a-z]/) || (STRUCTURED.include?(type) && %w[SpecID ContentID].include?(field))
    end

    def attributes(node)
      node.attributes.reject { |key, _| key == "xmlns" || key.start_with?("xmlns:") }
    end

    def children(node)
      node.parts.grep(XMLTree::Node)
    end

    def text(node)
      raise ConversionError, "nested XML has no scalar JSON representation" unless children(node).empty?

      node.parts.grep(String).join
    end

    def element_content(node)
      raise ConversionError, "mixed XML content has no JSON object representation" unless node.parts.grep(String).all? { |item| item.strip.empty? }
    end

    def expect_name(node, uri, name)
      raise ConversionError, "unsupported XML element or namespace" unless node.uri == uri && node.local == name
    end

    def read_object(node, type)
      if node.uri == SCI && node.local == "AttackPattern" && children(node).any? { |child| child.uri == SCI && child.local == "Scoring" }
        raise ConversionError, "AttackPattern cannot contain XML Scoring"
      end
      if STRUCTURED.include?(type) && children(node).any? { |child| child.local == "Reference" }
        raise ConversionError, "SCI Reference uses an incompatible IODEF namespace"
      end
      data = {}
      attributes(node).each do |name, value|
        uri, local = @tree.expand(name, node.namespaces, attribute: true)
        next if uri == XSI && %w[schemaLocation noNamespaceSchemaLocation].include?(local)

        field = uri == XMLTree::XML_NS && local == "lang" ? "lang" : local
        unless (uri.empty? || (uri == XMLTree::XML_NS && local == "lang")) && fields(type).key?(field) && attribute?(type, field) &&
               (field != "lang" || uri == XMLTree::XML_NS)
          raise ConversionError, "XML attribute has no JSON representation"
        end
        raise ConversionError, "duplicate mapped XML attribute" if data.key?(field)

        data[field] = scalar(value, descriptor(type, field))
      end
      if TEXT.key?(type)
        field = TEXT.fetch(type)
        if %w[Extension SoftwareReference].include?(type) && data["dtype"] == "xml"
          data[field] = fragment(node)
        else
          value = text(node)
          if %w[Extension SoftwareReference].include?(type) && %w[byte file bytes frame packet ipv4-packet ipv6-packet].include?(data["dtype"])
            value = value.gsub(/[\t\r\n ]/, "")
          end
          data[field] = scalar(value, descriptor(type, field)) unless value.empty? && !fields(type)[field].end_with?("!")
        end
      else
        element_content(node)
        children(node).each { |child| read_child(data, child, type) }
      end
      data["type"] ||= "unknown" if %w[SystemImpact BusinessImpact].include?(type)
      data["category"] ||= "ipv6-addr" if type == "Address"
      data
    end

    def read_child(data, child, type)
      wrapper = WRAPPERS.fetch(type, {}).key(child.local) if child.uri == NS
      if wrapper
        raise ConversionError, "wrapper attributes cannot be flattened without loss" unless attributes(child).empty?
        element_content(child)
        raise ConversionError, "empty XML wrapper" if children(child).empty?

        children(child).each do |nested|
          expect_name(nested, namespace(type, wrapper), xml_name(type, wrapper))
          add(data, wrapper, read_value(nested, descriptor(type, wrapper).delete_suffix("[]"), wrapper), type)
        end
        return
      end
      if type == "Assessment" && child.uri == NS && IMPACTS.include?(child.local)
        impact_type = child.local == "IntendedImpact" ? "BusinessImpact" : child.local
        add(data, "Impact", { child.local => read_object(child, impact_type) }, type)
        return
      end
      if %w[Indicator IndicatorExpression].include?(type) && child.uri == NS && child.local == "ObservableReference"
        raise ConversionError, "unsupported ObservableReference attributes" unless attributes(child).keys == ["uid-ref"]
        raise ConversionError, "ObservableReference must be empty" unless text(child).strip.empty?

        add(data, "uid-ref", scalar(child.attributes["uid-ref"], "id"), type)
        return
      end
      field = fields(type).keys.find { |candidate| !attribute?(type, candidate) && xml_name(type, candidate) == child.local && namespace(type, candidate) == child.uri }
      raise ConversionError, "XML child has no JSON representation" unless field && field != TEXT[type]
      raise ConversionError, "XML child requires its wrapper" if WRAPPERS.fetch(type, {}).key?(field)

      add(data, field, read_value(child, descriptor(type, field).delete_suffix("[]"), field), type)
    end

    def read_value(node, type, field)
      raise ConversionError, "XML cryptographic structures have no unambiguous JSON byte mapping" if OPAQUE.include?(field)

      if type == "mlstring"
        data = read_object(node, "MLString")
        data["lang"] ||= node.lang if node.lang
        return data["value"] if (data.keys - %w[value lang]).empty? && [nil, "en"].include?(data["lang"])

        data
      elsif SCHEMA.key?(type)
        read_object(node, type)
      elsif field == "RawData"
        raise ConversionError, "RawData attributes have no JSON representation" unless attributes(node) == { "dtype" => "xml" }
        element_content(node)
        raise ConversionError, "RawData must contain one XML document" unless children(node).size == 1

        bytes = @tree.serialize(children(node).first)
        raise LimitError, "RawData exceeds max_binary_size" if bytes.bytesize > @limits[:max_binary_size]

        [bytes].pack("m0")
      else
        raise ConversionError, "scalar XML attributes have no JSON representation" unless attributes(node).empty?

        scalar(text(node), type)
      end
    end

    def add(data, field, value, type)
      if descriptor(type, field).end_with?("[]")
        values = data[field] ||= []
        raise LimitError, "collection exceeds max_collection_size" if values.size >= @limits[:max_collection_size]

        values << value
      else
        raise ConversionError, "repeated XML element has no singular JSON representation" if data.key?(field)

        data[field] = value
      end
    end

    def scalar(value, type)
      case type
      when "integer"
        raise ConversionError, "invalid XML integer" unless value.strip.match?(/\A[+-]?[0-9]+\z/)

        Integer(value.strip, 10)
      when "number", "positive"
        number = value.strip
        raise ConversionError, "invalid XML number" unless number.match?(/\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/)

        result = number.match?(/\A[+-]?[0-9]+\z/) ? Integer(number, 10) : Float(number)
        raise ConversionError, "non-finite XML number" if result.is_a?(Float) && !result.finite?

        result
      when "id", "language", "datetime", "uri", "timezone", "portlist" then value.strip.gsub(/[\t\r\n ]+/, " ")
      when "binary" then value.gsub(/[\t\r\n ]/, "")
      else ENUMS.key?(type) ? value.strip.gsub(/[\t\r\n ]+/, " ") : value
      end
    end

    def fragment(node)
      writer = XMLTree::Writer.new(@limits)
      node.parts.each do |part|
        case part
        when XMLTree::Node then @tree.write_node(writer, part)
        when XMLTree::Markup
          writer.append(part.kind == :comment ? "<!--#{part.value}-->" : "<?#{part.value}?>")
        else writer.text(part)
        end
      end
      writer.value
    end

    def namespace(type, field)
      return DS if OPAQUE.include?(field) || (type == "Digest" && field == "DigestValue")
      return ENUM if field == "ReferenceName" || type == "ReferenceName"
      return SCI if %w[AttackPattern Vulnerability Weakness Platform Scoring RawData].include?(field)

      NS
    end

    def xml_name(type, field)
      return "Nameservers" if type == "DomainData" && field == "NameServers"
      return "Value" if type == "Key" && field == "KeyValue"

      field
    end

    def write_object(writer, name, data, type, language, extra_attributes = {})
      raise ConversionError, "unknown JSON property has no XML representation" unless (data.keys - fields(type).keys).empty?
      raise ConversionError, "AttackPattern cannot contain XML Scoring" if name == "AttackPattern" && data.key?("Scoring")
      raise ConversionError, "SCI Reference uses an incompatible IODEF namespace" if STRUCTURED.include?(type) && data.key?("Reference")

      attrs = extra_attributes.dup
      attrs["xmlns"] = NS if type == "Document"
      data.each do |field, value|
        next unless attribute?(type, field)

        attrs[field == "lang" ? "xml:lang" : field] = type == "Document" && field == "version" ? "2.00" : value
      end
      language = data.fetch("lang", language)
      writer.open(name, attrs)
      if TEXT.key?(type)
        value = data[TEXT.fetch(type)]
        if value
          if %w[Extension SoftwareReference].include?(type) && data["dtype"] == "xml"
            write_fragment(writer, value)
          else
            writer.text(value)
          end
        end
      else
        order = ORDER.fetch(type) { fields(type).keys.reject { |field| attribute?(type, field) } }
        order.each do |field|
          next unless data.key?(field)

          write_field(writer, field, data[field], type, language)
        end
        omitted = data.keys.reject { |field| attribute?(type, field) || order.include?(field) }
        raise ConversionError, "JSON property has no ordered XML representation" unless omitted.empty?
      end
      writer.close(name)
    end

    def write_field(writer, field, value, type, language)
      values = descriptor(type, field).end_with?("[]") ? value : [value]
      wrapper = WRAPPERS.fetch(type, {})[field]
      writer.open(wrapper) if wrapper
      values.each do |item|
        if type == "Assessment" && field == "Impact"
          raise ConversionError, "unknown Impact property has no XML representation" unless item.size == 1

          impact, content = item.first
          write_object(writer, impact, content, impact == "IntendedImpact" ? "BusinessImpact" : impact, language)
        elsif %w[Indicator IndicatorExpression].include?(type) && field == "uid-ref"
          writer.open("ObservableReference", { "uid-ref" => item })
          writer.close("ObservableReference")
        else
          write_value(writer, field, item, descriptor(type, field).delete_suffix("[]"), type, language)
        end
      end
      writer.close(wrapper) if wrapper
    end

    def write_value(writer, field, value, type, parent, language)
      raise ConversionError, "XML cryptographic structures have no unambiguous JSON byte mapping" if OPAQUE.include?(field)

      uri = namespace(parent, field)
      name = xml_name(parent, field)
      extra = {}
      extra["xmlns"] = uri if uri != NS || STRUCTURED.include?(parent)
      if type == "mlstring"
        content = value.is_a?(String) ? { "value" => value } : value
        extra["xml:lang"] = "en" if value.is_a?(String) && language && language != "en"
        write_object(writer, name, content, "MLString", language, extra)
      elsif SCHEMA.key?(type)
        write_object(writer, name, value, type, language, extra)
      elsif field == "RawData"
        bytes = value.unpack1("m0")
        node = @tree.parse(bytes)
        writer.open(name, extra.merge("dtype" => "xml"))
        @tree.write_node(writer, node)
        writer.close(name)
      else
        writer.open(name, extra)
        writer.text(value)
        writer.close(name)
      end
    rescue ParseError
      raise ConversionError, "embedded XML is not representable"
    end

    def write_fragment(writer, value)
      root = @tree.parse("<fragment>#{value}</fragment>")
      root.parts.each do |part|
        case part
        when XMLTree::Node then @tree.write_node(writer, part)
        when XMLTree::Markup
          writer.append(part.kind == :comment ? "<!--#{part.value}-->" : "<?#{part.value}?>")
        else writer.text(part)
        end
      end
    rescue ParseError
      raise ConversionError, "embedded XML is not representable"
    end
  end
end
