/// A safe-to-log summary of a `DecodingError`: the failing key path and the type Swift
/// expected there. `CodingKey` components and Swift type names are schema metadata (field
/// names like `resets_at`, types like `Double`), never response contents — so this never
/// needs to touch the payload to be useful.
import Foundation

/// Returns `"keyPath=<path> expected=<type>"` for a `DecodingError`, or a fixed string for
/// any other error shape. Internal (not `private`) so `@testable import TokiLimits` can
/// assert on it directly without needing the logging system bootstrapped.
func decodingDiagnostic(_ error: any Error) -> String {
    guard let decodingError = error as? DecodingError else {
        return "keyPath=<n/a> expected=<non-decoding error>"
    }

    let path: [CodingKey]
    let expected: String
    switch decodingError {
    case .typeMismatch(let type, let context):
        path = context.codingPath
        expected = String(describing: type)
    case .valueNotFound(let type, let context):
        path = context.codingPath
        expected = String(describing: type)
    case .keyNotFound(let key, let context):
        path = context.codingPath + [key]
        expected = "<required key>"
    case .dataCorrupted(let context):
        path = context.codingPath
        expected = "<valid JSON>"
    @unknown default:
        path = []
        expected = "<unknown>"
    }

    let keyPath = path.map(\.stringValue).joined(separator: ".")
    return "keyPath=\(keyPath.isEmpty ? "<root>" : keyPath) expected=\(expected)"
}
