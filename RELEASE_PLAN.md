# Release readiness

Canonical repository: `maromocooo/Iterune`.
Source publication and formal application distribution are separate decisions.
Neither visibility changes nor release publication are performed by build scripts.

## Implemented

- [x] Library backup/restore, corrupt SQLite preservation, concurrent-writer protection
- [x] AI improvement proposals, strict patches, fixed base version, opt-in run context, resumable drafts
- [x] Claude/Codex/Gemini history adapters with explicit version evidence and stable reimport
- [x] History search/rating/filter/delete, collection window, exclusions, deleted-run tombstones
- [x] Source-origin policy, frozen Publish confirmation, byte-exact checks, private backup and atomic replacement
- [x] Library edit versus observed source state; preserve unpublished edits and handle partial persistence failure
- [x] Four languages, first-use guidance, connection diagnostics, local tests
- [x] Neutral agent text badges without bundled vendor logos
- [x] Manual canonical update check, resource verification, Universal/source archive tooling
- [x] Parameterized Developer ID/notarization tooling (actual submission remains unverified)

## Remaining verification and release gates

- [ ] Review changes before publishing an application release
- [ ] Review repository metadata, documentation and any release attachments before publication
- [ ] Keep vendor artwork out of distributable resources unless applicable redistribution terms are verified
- [ ] Register and execute macOS CI; keep live tests opt-in
- [ ] Developer ID Application certificate, notarization profile, actual submission and stapling
- [ ] Clean Mac, macOS 14 minimum version and native Intel validation
- [ ] Real OpenAI/Anthropic API account/model smoke tests with explicit opt-in and synthetic inputs
- [ ] Real Claude/Gemini history format coverage beyond synthetic fixtures, using separately authorized testing
- [ ] Browser-download/Gatekeeper startup, version/update display and release asset review

See [verification](VERIFICATION.md), [distribution procedure](RELEASING.md), and
[artwork policy](BRAND_ASSETS.md). Output comments, artifact snapshots, Before/After,
automatic reruns, Fork, routing integrations and cloud features remain separate work.
