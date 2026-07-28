# Poppler runtime publication blocker

Status: **blocked pending qualified third-party review**.

The zero-setup Windows runtime is technically integrated and pinned, but a
helper-bearing RBZ must not be published as stable until an independent
qualified reviewer closes the exact 22-binary dependency/license record.

The current payload includes Poppler utilities, their PE-reachable DLLs, and
the complete packaged `share/poppler` data tree. The manifest records every
runtime member by size and SHA-256. `third_party/sources/SHA256SUMS.txt` pins
the upstream Windows binary archive and official Poppler data archive.

Those integrity facts do not establish that the four currently packaged
license files close every dependency-specific notice, license-text,
corresponding-source, or written-offer obligation. Until that review is
complete:

- `license_review.status` remains `blocked`;
- `build_release.py` rejects helper-bearing release builds;
- the bundled runtime is not treated as approved by the extension; and
- no stable release or website update may advertise this runtime.

Approval requires a checked-in evidence record, a checked-in source checksum
inventory, a UTC review timestamp, no missing obligations, and an independent
reviewer identity. Product doctrine, an automated process, or an AI
contributor cannot self-approve the record.
