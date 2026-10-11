# IODEF

Read, validate, build, and exchange incident reports using the JSON binding of IODEF v2 ([RFC 8727](https://www.rfc-editor.org/rfc/rfc8727.html), with the information model in [RFC 7970](https://www.rfc-editor.org/rfc/rfc7970.html)).

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

Install with `gem install iodef`. Ruby 3.3 or newer, JRuby, and TruffleRuby are supported. The only required runtime gem is `json` (2.19.4 or newer, including 3.x); no other gem from this project is required. `IODEF` and `Iodef` refer to the same module.

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
| `max_nodes` | 200,000 JSON/CBOR values |
| `max_binary_size` | 1 MiB per decoded binary value |
| `max_violations` | 1,000 diagnostics |

Pass overrides to `parse`, `validate`, `parse_cbor`, or model constructors. Limits are positive integers. Resource-limit failures raise `LimitError` even in inspection mode. Malformed/duplicate-key JSON raises `ParseError`; cycles, nonfinite numbers, invalid string encodings, and non-JSON Ruby objects are rejected. Diagnostics identify properties and rules without including incident values.

## CBOR

Load the built-in Ruby codec:

```ruby
require "iodef/cbor"
bytes = document.to_cbor
copy = IODEF.parse_cbor(bytes)
```

All 207 numeric map keys are supported. The encoder uses date tag 0, base64 byte-string tag 22, hexadecimal byte-string tag 23, and URI tag 32. Dates and URI spelling are preserved. Typed byte content becomes binary; hex output uses uppercase. The decoder also accepts contextually untagged strings/bytes, as used in the RFC's own CBOR examples. Integer bignums are preserved. IODEF real values are encoded as float32; values that would round or overflow raise `ConversionError`. Unknown JSON floats keep their original precision.

Unknown CBOR tags, unassigned integer keys, and opaque byte strings without an IODEF type cannot be represented unambiguously in JSON and raise `ConversionError`. Duplicate/colliding keys, invalid UTF-8, excessive nesting, large collections, and trailing data are rejected during bounded decoding. JSON and CBOR are tested on CRuby, JRuby, and TruffleRuby, including CRuby development builds. No separate CBOR gem is required.

## Scope

| Supported in 0.1.0 | Outside 0.1.0 |
| --- | --- |
| JSON binding, all RFC 8727 class/property definitions | RFC 7970 XML import/export |
| Typed core models, multilingual text, builders | RID or other exchange transports |
| IODEF enum extensions and preserved unknown JSON fields | Vendor extension semantics |
| CBOR, numeric keys, typed binary values | Signing, encryption, threat correlation |
| RBS signatures and bounded validation | Authenticating senders or verifying referenced evidence |

The property metadata in `data/` describes the RFC field names, types, cardinalities, and protocol identifiers. CDDL, JSON Schema, RFC examples, and IANA source downloads are not embedded in the package. Tests inspect the downloaded CDDL as reference data; no third-party CDDL or CBOR implementation is loaded.

### Specification differences

RFC 8727's CDDL has a verified missing-brace correction ([erratum 7334](https://www.rfc-editor.org/errata/eid7334)). The temporary reference schema applies it. Its section 4.2 JSON example needs presentation-wrapped strings joined; the original text is retained beside the corrected fixture. Both complete JSON and CBOR examples are tested.

The JSON examples use version `2.0`; the XML information model uses `2.00`. Both spellings are accepted and preserved. Required nonempty child groups and conditional values follow RFC 7970: nonnumeric `Confidence` omits `value`, numeric confidence requires it; a node can include both addresses and domain data; `HashData` supports `ext-scope`. `RelatedActivity.Description` accepts multilingual strings. These constraints are not all accurately expressed in the RFC 8727 CDDL. The section 2.2.5 illustration uses a CWE `SpecID` absent from its normative enum: use `private` with `ext-SpecID` for that extension.

The pinned IANA registry and RFC have differing spellings for `breach-propietary` / `breach-proprietary`, `anonymization` / `anomyzation`, and `ntp-stamp` / `ntpstamp`; both are accepted. RFC 8727 additionally defines the `json` extension data type. This library validates format and structure, not whether a reported address, software identifier, or incident fact is authentic.

## Development

```sh
bundle install
bundle exec rake test
COVERAGE=1 bundle exec rake test
bundle exec rbs -I sig validate
bundle exec ruby script/benchmark.rb 5000
```

The fixture task verifies SHA-256-pinned RFC/IANA sources, retains source notices, and regenerates examples under ignored `tmp/rfc/`. Tests check both complete RFC JSON and CBOR examples, every CDDL object property, and the numeric map assignments. Original wire-format tests cover integer widths, floating-point precision, UTF-8 chunk boundaries, duplicate keys, tags, malformed values, limits, and randomized round trips. Reference data keeps its own license and notices even though it is not distributed with the gem.

`script/update_registry.rb` audits the pinned IANA metadata. `--refresh` downloads the current registry, rejects unexplained differences, and updates its checksum only after the audit succeeds. Review RFC errata and registry changes before refreshing. No downloaded reference material is tracked or included in the gem.

## License

Project code is MIT licensed; see [LICENSE.txt](LICENSE.txt). Added library dependencies are limited to MIT-licensed libraries. Ruby implementations and standard/default libraries (including JSON) are exceptions and retain their own licenses. Downloaded standards material is test reference data under its source terms and is neither committed nor packaged. These statements do not relicense third-party material.
