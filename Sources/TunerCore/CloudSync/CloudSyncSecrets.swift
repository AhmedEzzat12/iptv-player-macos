import CryptoKit
import Foundation

/// Playlist passwords never reach the sync folder in readable form. Each device has a Curve25519 key pair (the private
/// key stays on the device) and publishes its public key in its file. When a device writes its file, every playlist's
/// `secret` is encrypted once with a random key (AES-GCM), and that key is wrapped for each other device with a key
/// both can derive (X25519 between the writer's and the reader's keys, then HKDF). Only the devices listed can read it;
/// removed devices and devices without a key (older versions) get nothing.
///
/// Inside the app (database, ledger, merge) records carry the plain `secret`; only files carry `sealedSecret`.
public enum CloudSyncSecrets {
    static let sealedField = "sealedSecret"
    static let plainField = "secret"
    static let salt = Data("tuner-sync-secret-1".utf8)

    public typealias PrivateKey = Curve25519.KeyAgreement.PrivateKey
    public typealias PublicKey = Curve25519.KeyAgreement.PublicKey

    public static func publicKeyString(_ key: PrivateKey) -> String { key.publicKey.rawRepresentation.base64EncodedString() }

    public static func publicKey(_ string: String?) -> PublicKey? {
        guard let string, let data = Data(base64Encoded: string) else { return nil }
        return try? PublicKey(rawRepresentation: data)
    }

    /// The key that wraps content keys between two devices (the same on both ends).
    static func wrappingKey(_ own: PrivateKey, _ other: PublicKey, writer: String, reader: String) throws -> SymmetricKey {
        let shared = try own.sharedSecretFromKeyAgreement(with: other)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("\(writer)>\(reader)".utf8), outputByteCount: 32)
    }

    /// Records as written to the file: each `secret` replaced by a `sealedSecret` for `recipients` (device id → public
    /// key), or dropped when there is nobody to send it to.
    public static func seal(_ records: [CloudSyncRecord], writer: String, key: PrivateKey, recipients: [String: PublicKey]) -> [CloudSyncRecord] {
        records.map { record in
            guard case .object(var fields)? = record.value, let secret = fields.removeValue(forKey: plainField) else { return record }
            if let sealed = try? seal(secret, writer: writer, key: key, recipients: recipients) { fields[sealedField] = sealed }
            var out = record
            out.value = .object(fields)
            return out
        }
    }

    static func seal(_ secret: SyncJSON, writer: String, key: PrivateKey, recipients: [String: PublicKey]) throws -> SyncJSON? {
        guard !recipients.isEmpty else { return nil }
        let contentKey = SymmetricKey(size: .bits256)
        let plain = try JSONEncoder().encode(secret)
        guard let box = try AES.GCM.seal(plain, using: contentKey).combined else { return nil }
        let raw = contentKey.withUnsafeBytes { Data($0) }
        var keys: [String: SyncJSON] = [:]
        for (reader, publicKey) in recipients {
            let wrapping = try wrappingKey(key, publicKey, writer: writer, reader: reader)
            guard let wrapped = try AES.GCM.seal(raw, using: wrapping).combined else { continue }
            keys[reader] = .string(wrapped.base64EncodedString())
        }
        return .object(["v": .number(1), "box": .string(box.base64EncodedString()), "keys": .object(keys)])
    }

    /// A file's records as the app uses them: each `sealedSecret` this device can open becomes `secret` again; the
    /// others are dropped (the playlist then arrives without its password).
    public static func open(_ file: CloudSyncDeviceFile, reader: String, key: PrivateKey?) -> CloudSyncDeviceFile {
        let writerKey = publicKey(file.publicKey)
        var out = file
        out.records = file.records.map { record in
            guard case .object(var fields)? = record.value, let sealed = fields.removeValue(forKey: sealedField) else { return record }
            if let key, let writerKey, let secret = open(sealed, writer: file.deviceId, reader: reader, key: key, writerKey: writerKey) {
                fields[plainField] = secret
            }
            var r = record
            r.value = .object(fields)
            return r
        }
        return out
    }

    static func open(_ sealed: SyncJSON, writer: String, reader: String, key: PrivateKey, writerKey: PublicKey) -> SyncJSON? {
        guard let wrappedText = sealed["keys"]?[reader]?.string, let wrapped = Data(base64Encoded: wrappedText),
              let boxText = sealed["box"]?.string, let boxData = Data(base64Encoded: boxText),
              let wrapping = try? wrappingKey(key, writerKey, writer: writer, reader: reader),
              let raw = try? AES.GCM.open(AES.GCM.SealedBox(combined: wrapped), using: wrapping),
              let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: boxData), using: SymmetricKey(data: raw))
        else { return nil }
        return try? JSONDecoder().decode(SyncJSON.self, from: plain)
    }
}
