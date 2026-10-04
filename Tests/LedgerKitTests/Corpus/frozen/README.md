# frozen/

**Populated at `0.1.0` (M9 Phase 4, 2026-10-04):** `0.1.0/` holds the eleven
`dev/` fixtures as they stood on the release candidate, byte-for-byte. See
../README.md for the freeze procedure — and note the order, which that file had
wrong until M9: freeze on the candidate, *then* tag.

Once a version's fixtures land here they are never regenerated, and
`CorpusFileTests.frozenFixturesAreIntact` has no record-mode branch that could
rewrite them. A diff under this directory is a regression; the remedy is an
upcaster (ADR-001), never an edit.
