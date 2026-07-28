Poppler runtime license review notes

This directory preserves the license files carried by poppler-data 0.4.12 and
adds the official GNU GPLv3 text as a separately pinned file. See
../THIRD_PARTY_NOTICES.txt and ../../poppler-runtime-manifest.json for exact
source URLs, hashes, and the per-binary component/license identifier mapping.

These files are not asserted to close all obligations for the pruned Windows
binary dependency graph. PUBLICATION IS BLOCKED until a qualified reviewer
sets the manifest license_review status to "approved" with no missing items.
The release builder enforces that state; structural and semantic smoke tests do
not bypass it.
