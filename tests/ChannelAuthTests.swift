import Foundation
import CryptoKit

@main @MainActor
struct ChannelAuthTests {
    static var failures = 0
    static func check(_ ok: Bool, _ msg: String, line: Int = #line) {
        if !ok { failures += 1; print("FAIL line \(line): \(msg)") }
    }

    static func main() throws {
        // Vectors computed independently with Python's hmac/hashlib (see tests/relay).
        let key = SymmetricKey(data: ChannelAuth.hexBytes("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")!)
        let nonce = "0123456789abcdef0123456789abcdef"
        let body = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash"}"#.utf8)
        let reqMac = "370cc7f0dabe1007f5382e07e232eb8d00ae7412e929f24e90476d9b89b74cac"
        let repMac = "101b5fedb683cda7f3289b0e5400fcf0bd9980a7f79cdbfd6cb11ac509454166"

        check(ChannelAuth.requestHeader(for: body, nonce: nonce, key: key) == "BIPUU1 \(nonce) \(reqMac)", "request MAC matches the Python vector")
        check(ChannelAuth.authenticate(header: "BIPUU1 \(nonce) \(reqMac)", body: body, key: key) == nonce, "valid request authenticates")
        let reply = Data(#"{"permissionDecision":"allow"}"#.utf8)
        check(ChannelAuth.replyHeader(for: reply, nonce: nonce, key: key) == "BIPUU1R \(repMac)", "reply MAC matches the Python vector")

        // Anything off is rejected.
        check(ChannelAuth.authenticate(header: "BIPUU1 \(nonce) \(reqMac)", body: body + Data("x".utf8), key: key) == nil, "tampered body")
        check(ChannelAuth.authenticate(header: "BIPUU1 \(nonce.replacingOccurrences(of: "0", with: "1")) \(reqMac)", body: body, key: key) == nil, "different nonce")
        check(ChannelAuth.authenticate(header: "BIPUU1 \(nonce) \(repMac)", body: body, key: key) == nil, "a reply MAC is not a request MAC")
        check(ChannelAuth.authenticate(header: "BIPUU1 \(nonce) \(reqMac)", body: body, key: SymmetricKey(data: Data(repeating: 7, count: 32))) == nil, "wrong key")
        for bad in ["", "BIPUU1", "BIPUU1 \(nonce)", "BIPUU2 \(nonce) \(reqMac)", "BIPUU1 \(nonce) \(reqMac) extra",
                    "BIPUU1 short \(reqMac)", "BIPUU1 \(nonce.uppercased()) \(reqMac)", "BIPUU1 \(nonce) zz", "BIPUU1 \(nonce) \(reqMac.dropLast(2))"] {
            check(ChannelAuth.authenticate(header: bad, body: body, key: key) == nil, "malformed header rejected: \(bad)")
        }

        // Key file: created 0600, reloaded identically, refused when others can read it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bipuu-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("channel.key")
        let k1 = try ChannelAuth.loadOrCreateKey(at: url)
        var st = stat(); stat(url.path, &st)
        check(st.st_mode & 0o777 == 0o600, "key file is 0600 (got \(String(st.st_mode & 0o777, radix: 8)))")
        let k2 = try ChannelAuth.loadOrCreateKey(at: url)
        check(k1.withUnsafeBytes { Data($0) } == k2.withUnsafeBytes { Data($0) }, "key is stable across loads")
        check(k1.withUnsafeBytes { Data($0) }.count == 32, "key is 32 bytes")
        chmod(url.path, 0o644)
        do { _ = try ChannelAuth.loadOrCreateKey(at: url); check(false, "world-readable key must be refused") }
        catch ChannelAuth.KeyError.wrongPermissions { }
        catch { check(false, "wrong error \(error)") }
        chmod(url.path, 0o600)
        try "not hex\n".write(to: url, atomically: true, encoding: .utf8); chmod(url.path, 0o600)
        do { _ = try ChannelAuth.loadOrCreateKey(at: url); check(false, "malformed key must be refused") }
        catch ChannelAuth.KeyError.malformed { }
        catch { check(false, "wrong error \(error)") }

        if failures == 0 { print("Channel auth: all cases passed") } else { print("\(failures) failure(s)"); exit(1) }
    }
}
