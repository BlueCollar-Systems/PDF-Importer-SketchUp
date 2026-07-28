# Poppler runtime publication blocker

Status: **blocked pending qualified third-party review**.

The zero-setup Windows runtime is technically integrated and pinned, but a
helper-bearing RBZ must not be published as stable until an independent
qualified reviewer closes the exact 22-binary dependency/license record.

The current payload includes Poppler utilities, their PE-reachable DLLs, and
the complete packaged `share/poppler` data tree. The manifest records every
runtime member by size and SHA-256. `third_party/sources/SHA256SUMS.txt` pins
the upstream Windows binary archive and official Poppler data archive. The
checked-in compliance package maps all 19 packaged components to 23
authoritative upstream license texts; its provenance and hashes are recorded
in `third_party/sources/license-fetch-provenance.json` and
`third_party/sources/LICENSE_TEXT_SHA256SUMS.txt`.

That evidence is materially stronger than the earlier four-file payload, but
it is not a legal determination. The written source offer still contains
owner/contact/publication placeholders, and a qualified reviewer has not
approved the exact package. Until both are complete:

- `license_review.status` remains `blocked`;
- `build_release.py` rejects helper-bearing release builds;
- the bundled runtime is not treated as approved by the extension; and
- no stable release or website update may advertise this runtime.

Approval requires a checked-in evidence record, a checked-in source checksum
inventory, a completed source offer with owner contact and source-publication
details, a UTC review timestamp, no missing obligations, and an independent
qualified reviewer identity. Product doctrine, an automated process, or an AI
contributor cannot self-approve the record. The manifest builder enforces the
required compliance inventory and rejects draft source-offer placeholders.
