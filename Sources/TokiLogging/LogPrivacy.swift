/// How a `String` is rendered into a log line. There is no case that prints an
/// arbitrary string verbatim *and* skips the redactor: `Redactor` runs over every
/// finished line whatever is chosen here.
public enum LogPrivacy: Sendable {
    /// Safe as written: an enum case name, an HTTP status, a model identifier.
    case `public`
    /// Replaced by `<redacted>`. Use when even a correlation token is pointless.
    case redacted
    /// Replaced by `value#a3f1c204` — stable within one install, unrecoverable,
    /// and not comparable across installs. Use to correlate without revealing.
    case hashed
}
