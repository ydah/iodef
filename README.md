# IODEF

Read, validate, build, and exchange IODEF v2 incident reports as JSON, CBOR, or XML ([RFC 8727](https://www.rfc-editor.org/rfc/rfc8727.html) and [RFC 7970](https://www.rfc-editor.org/rfc/rfc7970.html)).

```ruby
require "iodef"

document = IODEF.parse(json)
incident = document.incidents.first
incident.incident_id
incident.contacts.first.role
incident.description.text("ja")

issues = IODEF.validate(json)
issues.each { |issue| puts "#{issue.pointer}: #{issue.rule}: #{issue.message}" }
```

Install with `gem install iodef`. Ruby 3.3 or newer, JRuby, and TruffleRuby are supported. Runtime dependencies are the Ruby standard libraries `json` (2.19.4 or newer, including 3.x) and `rexml` (3.4.4 or newer, below 4); no other gem from this project is required. `IODEF` and `Iodef` refer to the same module.

## Build and edit a report

```ruby
document = IODEF::Document.build(lang: "en") do |doc|
  doc.add_incident(purpose: "reporting") do |incident|
    incident.incident_id = { id: "case-24", name: "response.example" }
    incident.generation_time = "2026-10-01T09:00:00Z"
    incident.description = ["Unexpected traffic", { value: "不審な通信", lang: "ja" }]
    incident.add_contact(role: "creator", type: "organization") do |contact|
      contact.contact_name = ["Response team"]
      contact.email = [{ "EmailTo" => "response@response.example" }]
    end
  end
end

json = document.to_json
```

Builders require the incident's ID, generation time, and at least one contact. They do not invent reporting identities or timestamps. Known properties use snake_case accessors; wire property names retain their RFC spelling. `Document`, `Incident`, `Contact`, `Assessment`, `EventData`, and `Indicator` have typed views. Other objects are ordinary hashes. Plural conveniences include `incidents`, `contacts`, `assessments`, and `indicators`.

Typed child views update their document. `[]` exposes the underlying value, `[]=` copies the assigned value, and `to_h` returns a detached copy. Symbols in builder hashes become strings. Unknown JSON properties are preserved, including nested values and large integers. Defaults such as restriction levels are not inserted into the source data.

## Validation and limits

Parsing is strict by default. `IODEF.parse(json, strict: false)` returns a document with a `warnings` array of `Violation` objects. `validate: false` is a compatibility spelling for this inspection mode. `validate!` refreshes diagnostics after edits. Serialization always validates and raises `IODEF::ValidationError` with `violations` and the first JSON `pointer`.

Required properties, types, nonempty collections, enum values, extension selector pairs, identifiers/references, dates, binary encodings, and information-model conditions are checked. Unknown properties remain available as extensions; their semantics are not inferred. Validation never fetches referenced URLs, schemas, or other network resources. XML, JSON, or regex text embedded in a report is not executed. JSON-valued extension strings are checked for JSON syntax.

| Option | Default |
| --- | ---: |
| `max_input_size` | 16 MiB of input/output; also bounds copied string data |
| `max_depth` | 32 nested levels |
| `max_collection_size` | 10,000 members per array or object |
| `max_nodes` | 200,000 JSON/CBOR values or XML parsing nodes |
| `max_binary_size` | 1 MiB per decoded binary value |
| `max_violations` | 1,000 diagnostics |

Pass overrides to `parse`, `validate`, `parse_cbor`, `parse_xml`, or model constructors. Limits are positive integers. Resource-limit failures raise `LimitError` even in inspection mode. Malformed/duplicate-key JSON raises `ParseError`; cycles, nonfinite numbers, invalid string encodings, and non-JSON Ruby objects are rejected. Diagnostics identify properties and rules without including incident values.

## CBOR

Load the built-in Ruby codec:

```ruby
require "iodef/cbor"
bytes = document.to_cbor
copy = IODEF.parse_cbor(bytes)
```

All 207 numeric map keys are supported. The encoder uses date tag 0, base64 byte-string tag 22, hexadecimal byte-string tag 23, and URI tag 32. Dates and URI spelling are preserved. Typed byte content becomes binary; hex output uses uppercase. The decoder also accepts contextually untagged strings/bytes, as used in the RFC's own CBOR examples. Integer bignums are preserved. IODEF real values are encoded as float32; values that would round or overflow raise `ConversionError`. Unknown JSON floats keep their original precision.

Unknown CBOR tags, unassigned integer keys, and opaque byte strings without an IODEF type cannot be represented unambiguously in JSON and raise `ConversionError`. Duplicate/colliding keys, invalid UTF-8, excessive nesting, large collections, and trailing data are rejected during bounded decoding. JSON and CBOR are tested on CRuby, JRuby, and TruffleRuby, including CRuby development builds. No separate CBOR gem is required.

## XML

```ruby
require "iodef/xml"

document = IODEF.parse_xml(xml)
json = document.to_json
xml = IODEF.parse(json).to_xml
```

XML conversion accepts UTF-8 input and uses the RFC 7970 namespace `urn:ietf:params:xml:ns:iodef-2.0`. It maps attributes, element text, repeated children, and the wrapper elements removed by the JSON binding. Namespace prefixes are resolved by URI. Inherited `xml:lang` and multilingual text are preserved; unqualified JSON multilingual strings mean English. XML output uses version `2.00`, including when the input JSON uses `2.0`.

`parse_xml` accepts the same `strict: false` and `validate: false` inspection options as JSON parsing. Serialization validates again. Input size, depth, node count, and collection limits apply during XML parsing; serialized output is also bounded. DTDs and entity declarations are rejected, and no external resource is loaded.

Round trips preserve supported IODEF data, not XML formatting, namespace prefix choices, comments, or the original grouping of wrapper elements. XML-valued extensions preserve their namespace-qualified content, but their XML strings and base64-encoded XML bytes may be reserialized. `RawData` supports an embedded XML document with `dtype="xml"`; attributes without a JSON counterpart and other raw encodings cannot be converted. XML Signature/X509 structures and unknown JSON properties without an unambiguous XML mapping raise `ConversionError`. Conversion does not verify or preserve digital signatures.

Structured-information `Reference` values are not converted because RFC 7203 references the IODEF v1 XML namespace, while this API exchanges IODEF v2. An `AttackPattern` containing `Scoring` is also rejected because that child is not permitted by RFC 7203. These values remain available in JSON and CBOR.

Numeric literals use Ruby integers and floats. Other consumers that apply XML Schema validation may round fields defined as `xs:float`.

## Scope

| Supported in 0.2.0 | Outside 0.2.0 |
| --- | --- |
| JSON binding, all RFC 8727 class/property definitions | Ambiguous binary XML structures and vendor extension semantics |
| Typed core models, multilingual text, builders | RID or other exchange transports |
| RFC 7970 XML conversion and IODEF enum extensions | XML Schema validation and XML Signature conversion |
| Preserved unknown JSON fields in JSON/CBOR | Automatic XML mapping of unknown JSON fields |
| CBOR, numeric keys, typed binary values | Signing, encryption, threat correlation |
| RBS signatures and bounded validation | Authenticating senders or verifying referenced evidence |

The property metadata in `data/` describes the RFC field names, types, cardinalities, and protocol identifiers. CDDL, JSON Schema, RFC examples, and IANA source downloads are not embedded in the package. Tests inspect the downloaded CDDL as reference data; no third-party CDDL or CBOR implementation is loaded.

### Specification differences

RFC 8727's CDDL has a verified missing-brace correction ([erratum 7334](https://www.rfc-editor.org/errata/eid7334)). The temporary reference schema applies it. Its section 4.2 JSON example needs presentation-wrapped strings joined; the original text is retained beside the corrected fixture. Both complete JSON and CBOR examples are tested.

The JSON examples use version `2.0`; the XML information model uses `2.00`. JSON and CBOR accept and preserve both spellings; XML output uses `2.00`. Required nonempty child groups and conditional values follow RFC 7970: nonnumeric `Confidence` omits `value`, numeric confidence requires it; a node can include both addresses and domain data; `HashData` supports `ext-scope`. `RelatedActivity.Description` accepts multilingual strings. These constraints are not all accurately expressed in the RFC 8727 CDDL. The section 2.2.5 illustration uses a CWE `SpecID` absent from its normative enum: use `private` with `ext-SpecID` for that extension.

The pinned IANA registry and RFC have differing spellings for `breach-propietary` / `breach-proprietary`, `anonymization` / `anomyzation`, and `ntp-stamp` / `ntpstamp`; both are accepted. RFC 8727 additionally defines the `json` extension data type. This library validates format and structure, not whether a reported address, software identifier, or incident fact is authentic.

## Development

```sh
bundle install
bundle exec rake test
COVERAGE=1 bundle exec rake test
bundle exec rbs -I sig validate
bundle exec ruby script/benchmark.rb 5000
```

The fixture task verifies SHA-256-pinned RFC/IANA sources, retains source notices, and regenerates examples under ignored `tmp/rfc/`. Tests check both complete RFC JSON and CBOR examples, both complete RFC 7970 XML documents, every CDDL object property, and the numeric map assignments. The printed XML campaign example uses the unregistered `fqdn` value; its derived fixture uses `domain-name` as described in [reported erratum 6163](https://www.rfc-editor.org/errata/eid6163), while the original remains a negative test. Original wire-format tests cover integer widths, floating-point precision, UTF-8 chunk boundaries, duplicate keys, tags, malformed values, limits, and randomized round trips. XML tests cover namespaces, language inheritance, escaping, DTD rejection, and bounded parsing. Reference data keeps its own license and notices even though it is not distributed with the gem.

`script/update_registry.rb` audits the pinned IANA metadata. `--refresh` downloads the current registry, rejects unexplained differences, and updates its checksum only after the audit succeeds. Review RFC errata and registry changes before refreshing. No downloaded reference material is tracked or included in the gem.

## License

Project code is MIT licensed; see [LICENSE.txt](LICENSE.txt). Added library dependencies are limited to MIT-licensed libraries. Ruby implementations and standard/default libraries (including JSON and REXML) are exceptions and retain their own licenses. Downloaded standards material is test reference data under its source terms and is neither committed nor packaged. These statements do not relicense third-party material.
