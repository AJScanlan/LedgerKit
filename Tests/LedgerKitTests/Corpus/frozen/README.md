# frozen/

Empty until `0.1.0` is tagged. See ../README.md for the freeze procedure.

Once a version's fixtures land here they are never regenerated, and
`CorpusFileTests.frozenFixturesAreIntact` has no record-mode branch that could
rewrite them. A diff under this directory is a regression; the remedy is an
upcaster (ADR-001), never an edit.
