/// What the app can do about a failure (SPEC §8).
///
/// **Derived, never persisted — deliberately not `Codable`.** Produced by the
/// classify layer's `(GenerationError) -> Recoverability` mapping; snapshots
/// store the error and recompute this on load. Persisting it would freeze
/// classification bugs into history; deriving it means they heal on the next
/// reduction. A test asserts the non-conformance.
public enum Recoverability: Sendable, Equatable {
    /// Transient — offer Retry / auto-backoff, after the given delay if known.
    case retryable(after: Duration?)
    /// The caller must change something first.
    case recoverableUpstream(RequiredAction)
    /// Regenerate-with-changes is the only path.
    case terminal
}

/// The "something" the caller must change for a `.recoverableUpstream`
/// failure (SPEC §8).
public enum RequiredAction: Sendable, Equatable {
    /// Deep-link Settings.
    case enableAppleIntelligence
    case awaitModelDownload
    /// Trigger compaction (app-side), then retry.
    case reduceContext
    /// Provider-package credential problem.
    case reauthenticate
}
