// LedgerKitTestSupport — deterministic test doubles for Foundation Models apps.
//
// Empty until M3, which lands `ScriptedLanguageModel` (SPEC §10.1): a
// `LanguageModel` conformer that plays a script — emit snapshot, wait, throw,
// complete — so the whole library tests with zero network and zero Apple
// Intelligence eligibility.
//
// This is a separate product on purpose. Because the protocol being conformed to
// is Apple's, the double is useful to *any* Foundation Models app rather than
// only to LedgerKit consumers — the spec calls it "the gateway drug."
//
// The conformance surface itself is OQ3 (spec §14): stub it behind an internal
// protocol at M3, bind to the real thing at M6. The *scripting* logic is
// beta-independent, which is why this milestone doesn't wait on a beta.
