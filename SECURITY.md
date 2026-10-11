# Security

Report suspected vulnerabilities privately through [GitHub's vulnerability reporting page](https://github.com/ydah/iodef/security/advisories/new). Include the gem version, Ruby engine, and a small synthetic reproducer. Do not include operational incident reports, personal data, credentials, or private indicators in public issues.

IODEF documents contain untrusted, potentially sensitive content. This library validates representation and selected information-model rules; it does not authenticate reports or enforce disclosure restrictions. Apply authorization, transport encryption, retention policies, and trusted source selection in the calling application. Do not execute embedded scripts, XML, regexes, or extension payloads. The library itself never fetches document-supplied URLs or schemas.

Size, depth, node, collection, binary, and diagnostic limits apply by default. Increase them only for known workloads. The Ruby CBOR decoder checks bounds while reading and accepts only the IODEF tag set. It never evaluates tags as application code. Invalid or ambiguous CBOR values fail instead of silently dropping information.
