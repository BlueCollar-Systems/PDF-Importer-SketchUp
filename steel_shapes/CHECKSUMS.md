# Checksums

Every immutable `steel-v*` release includes a release-bound `SHA256SUMS.txt`
asset beside its versioned ZIP and `latest` alias. The two ZIPs are required to
be byte-identical. Use the checksum manifest from the same release; do not copy
a digest from a different tag.

## Verify locally

PowerShell:

`Get-FileHash .\Structural-Steel-SU-Shapes-v1.0.1.zip -Algorithm SHA256`

macOS / Linux:

`shasum -a 256 Structural-Steel-SU-Shapes-v1.0.1.zip`
