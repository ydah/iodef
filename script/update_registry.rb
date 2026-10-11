# frozen_string_literal: true

require_relative "prepare_rfc_fixtures"
require_relative "../lib/iodef"

module IODEFRegistry
  REGISTRIES = {
    "Restriction" => "restriction", "Incident-purpose" => "purpose", "Incident-status" => "status",
    "Contact-role" => "contact_role", "Contact-type" => "contact_type", "RegistryHandle-registry" => "registry",
    "PostalAddress-type" => "postal_type", "Telephone-type" => "telephone_type", "Email-type" => "email_type",
    "Expectation-action" => "action", "Discovery-source" => "discovery_source", "SystemImpact-type" => "system_impact",
    "BusinessImpact-severity" => "business_severity", "BusinessImpact-type" => "business_impact", "TimeImpact-metric" => "time_metric",
    "TimeImpact-duration" => "duration", "Confidence-rating" => "rating", "NodeRole-category" => "node_category",
    "System-category" => "system_category", "System-ownership" => "ownership", "Address-category" => "address_category",
    "Counter-type" => "counter_type", "Counter-unit" => "counter_unit", "DomainData-system-status" => "system_status",
    "DomainData-domain-status" => "domain_status", "RecordPattern-type" => "pattern_type", "RecordPattern-offsetunit" => "offset_unit",
    "Key-registryaction" => "registry_action", "HashData-scope" => "hash_scope", "BulkObservable-type" => "bulk_type",
    "IndicatorExpression-operator" => "operator", "ExtensionType-dtype" => "dtype", "SoftwareReference-spec-id" => "software_spec",
    "SoftwareReference-dtype" => "software_dtype"
  }.freeze

  module_function

  def audit(path)
    xml = REXML::Document.new(File.read(path))
    checked = []
    xml.root.elements.each("registry") do |registry|
      title = registry.elements["title"].text
      type = REGISTRIES.fetch(title)
      values = registry.get_elements("record/value").map(&:text)
      values << "breach-proprietary" if type == "system_impact"
      values << "anomyzation" if type == "node_category"
      values.push("json", "ntpstamp") if type == "dtype"
      values << "ipv4-net-mask" if type == "address_category"
      unless values.uniq.sort == IODEF::ENUMS.fetch(type).sort
        raise "Registry drift: #{title}: #{values - IODEF::ENUMS.fetch(type)} / #{IODEF::ENUMS.fetch(type) - values}"
      end

      checked << title
    end
    raise "Missing registry" unless checked.sort == REGISTRIES.keys.sort

    puts "Audited #{checked.size} IANA enumerations (documented RFC spelling differences applied)"
  end

  def run(refresh: false)
    source = RFCFixtures::SOURCES.fetch("iodef2.xml")
    path = File.join(RFCFixtures::ROOT, "sources/iodef2.xml")
    if refresh
      FileUtils.mkdir_p(File.dirname(path))
      Tempfile.create("registry-", File.dirname(path)) do |file|
        raise "Registry download failed" unless system("curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
                                                       "--proto-redir", "=https", "--max-time", "60", source.fetch("url"), "--output", file.path)

        audit(file.path)
        manifest_path = File.join(__dir__, "rfc_sources.json")
        manifest = JSON.parse(File.read(manifest_path))
        manifest["sources"]["iodef2.xml"]["sha256"] = Digest::SHA256.file(file.path).hexdigest
        File.write(manifest_path, "#{JSON.pretty_generate(manifest)}\n")
        File.rename(file.path, path)
      end
    else
      RFCFixtures.prepare
      audit(path)
    end
  end
end

IODEFRegistry.run(refresh: ARGV.include?("--refresh")) if $PROGRAM_NAME == __FILE__
