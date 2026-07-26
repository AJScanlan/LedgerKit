import Foundation

/// What a scripted model does, in order.
///
/// ```swift
/// let script: Script = [
///     "A valley fold ",
///     .wait(.milliseconds(80)),
///     "brings the paper down.",
/// ]
/// ```
///
/// A bare string literal is a text fragment, which is the overwhelmingly common
/// step — so the common script never names a step at all. Everything else is a
/// static member on ``Step``.
///
/// Scripts carry no Foundation Models types and are available wherever Swift
/// runs; only ``ScriptedLanguageModel`` needs a platform that has the framework.
public struct Script: Sendable, ExpressibleByArrayLiteral, ExpressibleByStringLiteral {

    /// One instruction.
    ///
    /// A struct with static factories rather than an `enum`, deliberately.
    /// Steps are *written* by callers and never *read* by them — nothing
    /// switches over a step — so an enum's exhaustiveness buys nothing, while
    /// costing default arguments (`tokenCount:` below could not have one) and
    /// source stability every time a step is added. Apple's own
    /// `LanguageModelExecutorGenerationChannel.Response.Action` is this shape,
    /// for the same reasons.
    public struct Step: Sendable, ExpressibleByStringLiteral {

        enum Kind: Sendable {
            case emit(String, tokenCount: Int)
            case wait(Duration)
            case waitFor(Cue)
            case reportUsage(input: Int, output: Int, cached: Int, reasoning: Int)
            case reportMetadata([String: String])
            case fail(any Error)
        }

        let kind: Kind

        private init(_ kind: Kind) {
            self.kind = kind
        }

        /// A string literal is a text fragment.
        public init(stringLiteral value: String) {
            self.init(.emit(value, tokenCount: 1))
        }

        /// Produce a fragment of the response.
        ///
        /// Fragments are *deltas*: the framework accumulates them, and a
        /// consumer reading `ResponseStream` sees the growing whole. Two
        /// `.emit`s of `"A valley "` and `"fold"` are one response reading
        /// `"A valley fold"`.
        ///
        /// `tokenCount` defaults to 1 per fragment rather than to an estimate:
        /// a test double's job is to be predictable, and a plausible-looking
        /// token count that nothing can verify is worse than an obvious one.
        /// Set it when a test asserts on token accounting.
        public static func emit(_ text: String, tokenCount: Int = 1) -> Step {
            Step(.emit(text, tokenCount: tokenCount))
        }

        /// Sleep before the next step — the paced streaming that makes previews
        /// and demo recordings look real.
        ///
        /// Uses the player's clock, so a test may drive it without real time.
        /// For *deterministic* pauses prefer ``waitFor(_:)``, which parks until
        /// the test says otherwise instead of racing a duration.
        public static func wait(_ duration: Duration) -> Step {
            Step(.wait(duration))
        }

        /// Park here until the test releases the cue.
        ///
        /// The tool for asserting anything about a generation *while it is in
        /// flight*: cancel it, kill the process, switch branches, assert the
        /// partial. No sleeps, no polling, no flakes.
        public static func waitFor(_ cue: Cue) -> Step {
            Step(.waitFor(cue))
        }

        /// Report token usage.
        ///
        /// Foundation Models expects usage before generated text; a script may
        /// order it otherwise, because a double that cannot express a
        /// misbehaving provider cannot test a driver's response to one.
        public static func reportUsage(
            input: Int,
            output: Int,
            cached: Int = 0,
            reasoning: Int = 0
        ) -> Step {
            Step(.reportUsage(input: input, output: output, cached: cached, reasoning: reasoning))
        }

        /// Report response metadata — provider-reported model identity and the
        /// like.
        public static func reportMetadata(_ values: [String: String]) -> Step {
            Step(.reportMetadata(values))
        }

        /// Throw, ending the generation.
        ///
        /// Steps after this one never run, which is the point: a failure part
        /// way through a response is exactly the shape that leaves a partial
        /// behind.
        public static func fail(_ error: any Error) -> Step {
            Step(.fail(error))
        }
    }

    public var steps: [Step]

    public init(_ steps: [Step]) {
        self.steps = steps
    }

    public init(arrayLiteral elements: Step...) {
        self.init(elements)
    }

    /// A whole response in one fragment — the one-liner case.
    public init(stringLiteral value: String) {
        self.init([.emit(value)])
    }
}

/// What a model does once its scripts run out.
public enum ScriptExhaustion: Sendable {
    /// Throw ``ScriptExhausted``. The default: a test that asks for more
    /// responses than it scripted has a bug in the test or in the code, and
    /// either way silence is the wrong answer.
    case fail
    /// Replay the last script forever. For previews and demos, where "keep
    /// saying something" beats correctness.
    case repeatLast
    /// Start again from the first script.
    case loop
}

/// Thrown when a model is asked to respond and has no script left
/// (``ScriptExhaustion/fail``).
public struct ScriptExhausted: Error, CustomStringConvertible {
    /// How many scripts the model was given.
    public let scripted: Int
    /// Which request this was — 1-based, so `scripted: 2, requested: 3` reads
    /// as "the third request, and only two were scripted".
    public let requested: Int

    public var description: String {
        "the scripted model was asked for response \(requested) but was given \(scripted)"
    }
}
