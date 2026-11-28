import Foundation
import CommonCrypto

/// A profile's PIN: four digits « Who's Watching? » asks before
/// opening the profile, editing it or deleting it. Only a hash is stored,
/// in the profiles' list: PBKDF2-HMAC-SHA256 of the PIN with a random salt
/// and the profile's id, « pbkdf2$<rounds>$<salt>$<hash> » (Base64). The
/// PIN itself is never written anywhere.
///
/// It keeps a child out of a profile, as Netflix's does; four digits are
/// not a password against someone holding the device's files.
public enum ProfilePIN {

    /// Digits in a PIN.
    public static let length = 4
    static let rounds: UInt32 = 20_000
    static let saltLength = 16

    /// Four digits 0–9 (ASCII), nothing else.
    public static func isValid(_ pin: String) -> Bool {
        return pin.count == length && pin.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// The stored form of `pin` for the profile `profileID`, with a fresh salt.
    public static func hash(_ pin: String, profileID: String) -> String {
        var salt = [UInt8](repeating: 0, count: saltLength)
        if SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) != errSecSuccess {
            salt = (0..<saltLength).map { _ in UInt8.random(in: 0...255) }
        }
        return encode(pin, profileID: profileID, salt: Data(salt), rounds: rounds)
    }

    /// Whether `pin` is the one `stored` was made from.
    public static func matches(_ pin: String, hash stored: String, profileID: String) -> Bool {
        let parts = stored.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "pbkdf2", let rounds = UInt32(parts[1]),
              let salt = Data(base64Encoded: String(parts[2])) else { return false }
        let candidate = encode(pin, profileID: profileID, salt: salt, rounds: rounds)
        // The same time whatever the first difference.
        let a = Array(candidate.utf8), b = Array(stored.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func encode(_ pin: String, profileID: String, salt: Data, rounds: UInt32) -> String {
        let password = Array((profileID + ":" + pin).utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        let status = password.withUnsafeBufferPointer { passwordBuffer in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 passwordBuffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) },
                                 password.count, saltBytes, saltBytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, derived.count)
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return "pbkdf2$\(rounds)$\(salt.base64EncodedString())$\(Data(derived).base64EncodedString())"
    }
}
