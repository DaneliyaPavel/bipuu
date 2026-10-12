import Foundation
import CryptoKit

// MARK: - Authenticated hook channel (protocol "BIPUU1")
//
// The hook relay and the app talk over a user-private Unix socket. Socket permissions keep other
// users out; this layer makes each side prove it is the right peer, so a process that merely
// squats the socket path cannot answer an approval, and a message that was not produced by the
// relay is not acted on.
//
//   relay → app   BIPUU1 <nonce> <mac>\n<json>\n      mac = HMAC-SHA256(key, "bipuu1|"  + nonce + "|" + json)
//   app → relay   BIPUU1R <mac>\n<json>\n             mac = HMAC-SHA256(key, "bipuu1r|" + nonce + "|" + json)
//
// `key` is 32 random bytes created by the app (`channel.key`, mode 0600, same user only). The nonce
// is fresh per request and chosen by the relay, so a reply recorded earlier cannot be replayed.
//
// Boundary: this authenticates against code that cannot read the key file. Malware running as the
// same user can read it (and could equally edit the agent's own settings); see docs/SECURITY_BASELINE.md.
//
// Pure functions + one file helper: no UI, unit-tested standalone.

enum ChannelAuth {
    static let requestTag = "BIPUU1"
    static let replyTag = "BIPUU1R"
    static let nonceHexLength = 32
    static let keyByteCount = 32

    // MARK: Key file

    enum KeyError: Error { case unreadable, wrongPermissions, malformed }

    /// Loads the channel key, creating it (atomically, mode 0600) on first run.
    /// Refuses a key file that other users could read.
    static func loadOrCreateKey(at url: URL) throws -> SymmetricKey {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            var bytes = [UInt8](repeating: 0, count: keyByteCount)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw KeyError.unreadable }
            let hex = bytes.map { String(format: "%02x", $0) }.joined() + "\n"
            // O_EXCL + 0600 at creation: no window where the file is readable by others.
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                defer { close(fd) }
                let data = Array(hex.utf8)
                guard write(fd, data, data.count) == data.count else { throw KeyError.unreadable }
            } else if errno != EEXIST {
                throw KeyError.unreadable
            }
        }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { throw KeyError.unreadable }
        guard st.st_mode & 0o077 == 0 else { throw KeyError.wrongPermissions }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw KeyError.unreadable }
        guard let bytes = hexBytes(text.trimmingCharacters(in: .whitespacesAndNewlines)), bytes.count == keyByteCount else {
            throw KeyError.malformed
        }
        return SymmetricKey(data: bytes)
    }

    // MARK: Request / reply

    /// Checks a request header `BIPUU1 <nonce> <mac>` against its body. Returns the nonce when
    /// authentic, nil otherwise. The comparison is constant-time.
    static func authenticate(header: String, body: Data, key: SymmetricKey) -> String? {
        let parts = header.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == requestTag,
              parts[1].count == nonceHexLength, isLowerHex(parts[1]),
              parts[2].count == 64, let given = hexBytes(parts[2]) else { return nil }
        let message = Data("bipuu1|\(parts[1])|".utf8) + body
        guard HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: message, using: key) else { return nil }
        return parts[1]
    }

    /// `BIPUU1R <mac>` for a reply body, bound to the request's nonce.
    static func replyHeader(for body: Data, nonce: String, key: SymmetricKey) -> String {
        "\(replyTag) \(mac(tag: "bipuu1r", nonce: nonce, body: body, key: key))"
    }

    /// Request header, as the relay builds it. Used by tests and any native client.
    static func requestHeader(for body: Data, nonce: String, key: SymmetricKey) -> String {
        "\(requestTag) \(nonce) \(mac(tag: "bipuu1", nonce: nonce, body: body, key: key))"
    }

    static func mac(tag: String, nonce: String, body: Data, key: SymmetricKey) -> String {
        let message = Data("\(tag)|\(nonce)|".utf8) + body
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Helpers

    static func hexBytes(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out: [UInt8] = []; out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b); idx = next
        }
        return out
    }

    static func isLowerHex(_ s: String) -> Bool {
        s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
