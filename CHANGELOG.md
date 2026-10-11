# Changelog

## 0.2.1 - 2026-10-12

- Select the correct description language when plain English strings appear with translated text, and inherit document and incident languages for multilingual objects in typed views.
- Reject malformed processing-instruction targets when parsing XML and serializing XML extensions.

## 0.2.0 - 2026-10-12

- Read and write RFC 7970 XML incident reports with `IODEF.parse_xml` and `Document#to_xml`, including namespace-aware extensions and multilingual text.
- Bound XML parsing and output, reject DTDs, and report unsupported mappings instead of discarding data.
- Support CBOR across CRuby, JRuby, and TruffleRuby without a separate `cbor` gem.

## 0.1.0 - 2026-10-12

Initial release.
