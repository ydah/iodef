# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "tempfile"
require "rexml/document"

module RFCFixtures
  ROOT = File.expand_path("../tmp/rfc", __dir__)
  DIRECTORY = File.join(ROOT, "fixtures")
  SOURCES = JSON.parse(File.read(File.join(__dir__, "rfc_sources.json"))).fetch("sources").freeze

  module_function

  def fetch(source, path)
    unless File.file?(path)
      Tempfile.create("download-", File.dirname(path)) do |file|
        success = system("curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https",
                         "--retry", "3", "--connect-timeout", "10", "--max-time", "60", source.fetch("url"), "--output", file.path)
        raise "Download failed" unless success
        raise "Source checksum mismatch" unless Digest::SHA256.file(file.path).hexdigest == source.fetch("sha256")

        File.rename(file.path, path)
      end
    end
    raise "Source checksum mismatch: #{path}" unless Digest::SHA256.file(path).hexdigest == source.fetch("sha256")
  end

  def prepare
    FileUtils.mkdir_p(File.join(ROOT, "sources"))
    SOURCES.each { |name, source| fetch(source, File.join(ROOT, "sources", name)) }
    FileUtils.mkdir_p(DIRECTORY)
    xml = REXML::Document.new(File.read(File.join(ROOT, "sources/rfc8727.xml")))
    xml.elements.each("//sourcecode") do |element|
      name = element.attributes["pn"]
      original = element.texts.map(&:value).join
      File.write(File.join(DIRECTORY, "#{name}.original.txt"), original)
      if %w[section-4.1-3.1 section-4.2-3.1].include?(name)
        hex = original.lines.map { |line| line.split("#").first.to_s }.join.gsub(/\s/, "")
        raise "Invalid CBOR hex example" unless hex.match?(/\A(?:[0-9A-Fa-f]{2})+\z/)

        File.binwrite(File.join(DIRECTORY, "#{name}.cbor"), [hex].pack("H*"))
      end
      next unless %w[section-4.1-2.1 section-4.2-2.1].include?(name)

      # Presentation-wrapped strings in section 4.2 are invalid literal JSON.
      json = original.gsub(/"(?:[^"\\]|\\.)*"/m) { |string| string.gsub(/\n\s*/, " ") }
      File.write(File.join(DIRECTORY, "#{name}.json"), "#{JSON.pretty_generate(JSON.parse(json))}\n")
    end
    cddl = File.read(File.join(DIRECTORY, "section-6-2.1.original.txt"))
    cddl = cddl.sub(%r{(iodef-BusinessImpact => BusinessImpact) /}, '\1} /')
    File.write(File.join(DIRECTORY, "iodef.cddl"), cddl)
    # The CDDL normative map keys describe CBOR; JSON additionally removes semantic tags.
    json_cddl = cddl.gsub(/^iodef-([\w-]+) = -?\d+$/) { "iodef-#{Regexp.last_match(1)} = #{Regexp.last_match(1).to_json}" }
    json_cddl = json_cddl.gsub(/\b(?:tdate|uri|eb64legacy)\b/, "text").gsub(/\bfloat32\b/, "number")
    File.write(File.join(DIRECTORY, "iodef-json.cddl"), json_cddl)
    prepare_xml_examples
    File.write(File.join(DIRECTORY, "LICENSE"), <<~NOTICE)
      Temporary conformance data extracted from RFC 7970 and RFC 8727.
      Copyright (c) 2016, 2020 IETF Trust and the persons identified as document authors.
      All rights reserved.
      Redistribution and use in source and binary forms, with or without
      modification, is permitted pursuant to, and subject to the license terms
      contained in, the Revised BSD License set forth in Section 4.c of the
      IETF Trust's Legal Provisions Relating to IETF Documents
      (https://trustee.ietf.org/license-info).
      Full original documents, copyright notices and authors are in ../sources/.
      Source: https://www.rfc-editor.org/rfc/rfc8727.xml
      Source: https://www.rfc-editor.org/rfc/rfc7970.txt
      Corrections: campaign string presentation wrapping; verified erratum 7334
      closes the missing BusinessImpact map brace in CDDL. The JSON oracle uses
      text property names, textual dates/URIs/base64 and JSON number primitives.
      Original examples and original CDDL are retained adjacent to corrections.
      RFC 7970 XML examples: page headers, footers and document indentation
      are removed. Section 7.2 changes BulkObservable type "fqdn" to
      "domain-name", following sections 3.29.3.1 and 8 and reported (not
      verified) erratum 6163: https://www.rfc-editor.org/errata/eid6163.
      The original XML is retained alongside the corrected example; all four
      campaign domains and string whitespace are preserved.
    NOTICE
    puts "Verified reference sources and prepared temporary RFC examples"
  end

  def prepare_xml_examples
    source = File.read(File.join(ROOT, "sources/rfc7970.txt"))
    text = source.lines.reject do |line|
      line.start_with?("Danyliw ", "RFC 7970 ") || line.include?("\f")
    end.join
    examples = text.match(/^7\.  Examples\n(.*?)^8\.  The IODEF Data Model/m)&.captures&.first
    raise "RFC 7970 example section missing" unless examples

    documents = examples.scan(/<\?xml version="1\.0".*?<\/IODEF-Document>/m)
    raise "Expected two complete RFC 7970 XML examples" unless documents.length == 2

    documents.each_with_index do |document, index|
      original = "#{document.gsub(/^ {3}/, "")}\n"
      name = "rfc7970-section-7.#{index + 1}"
      File.write(File.join(DIRECTORY, "#{name}.original.xml"), original)
      # The printed campaign example uses a value absent from its own enumeration.
      corrected = original.sub('<BulkObservable type="fqdn">', '<BulkObservable type="domain-name">')
      raise "Invalid RFC 7970 XML example" unless REXML::Document.new(corrected).root&.name == "IODEF-Document"

      File.write(File.join(DIRECTORY, "#{name}.xml"), corrected)
    end
  end
end

RFCFixtures.prepare if $PROGRAM_NAME == __FILE__
