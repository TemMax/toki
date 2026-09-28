import Foundation

/// Credential bytes and the framing used by `security find-generic-password -w`.
/// Never interpret arbitrary output as a credential: both literal and hex output must
/// decode to a JSON object. Hex is a transport representation, not a second stored format.
public enum CredentialJSON {
    public enum Invalid: Error { case objectRequired }
    private static let maximumSize = 1_048_576

    public static func canonical(_ data: Data) throws -> Data {
        guard data.count <= maximumSize,
              // no-log: callers log the typed invalid-input error without credential/parser details.
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Invalid.objectRequired
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func fromSecurityOutput(_ output: Data) -> Data? {
        guard output.count <= maximumSize * 2 + 1 else { return nil }
        // Remove the command's terminator only. A newline encoded IN hex is item data.
        var data = output
        if data.last == 0x0A { data.removeLast() }
        // no-log: literal JSON is one of two expected transport formats; caller logs total failure.
        if (try? canonical(data)) != nil { return data }
        guard !data.isEmpty, data.count.isMultiple(of: 2) else { return nil }
        let bytes = Array(data)
        var decoded = Data(capacity: bytes.count / 2)
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: byte - 48
            case 65...70: byte - 55
            case 97...102: byte - 87
            default: nil
            }
        }
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            decoded.append(high * 16 + low)
        }
        // no-log: SecurityCLIReader logs invalid transport without exposing its contents.
        guard (try? canonical(decoded)) != nil else { return nil }
        return decoded
    }
}
