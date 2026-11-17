
import Foundation
import CryptoKit
import NIOSSH

// MARK: - Trusted SSH Host

struct TrustedHost: Codable, Equatable {
    let hostname: String
    let port: Int
    let fingerprint: String
    let trustedDate: Date
}

// MARK: - Trusted Host Storage

@MainActor
final class TrustedHosts {
    static let shared = TrustedHosts()

    private var hosts: [TrustedHost] = []

    private var fileURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("BaudRogue", isDirectory: true)
        .appendingPathComponent("trusted-hosts.json")
    }

    private init() {
        load()
    }

    enum VerificationResult {
        case trusted
        case unknown
        case changed
    }

    // OpenSSH-compatible SHA256 fingerprint

    nonisolated static func fingerprint(
        for key: NIOSSHPublicKey
    ) -> String {
        let publicKey = String(openSSHPublicKey: key)
        let components = publicKey.split(separator: " ")

        guard components.count >= 2,
              let keyData = Data(base64Encoded: String(components[1]))
        else {
            return ""
        }

        let digest = SHA256.hash(data: keyData)

        let encoded = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")

        return "SHA256:\(encoded)"
    }

    // MARK: - Verify Host

    func verify(
        hostname: String,
        port: Int,
        fingerprint: String
    ) -> VerificationResult {
        let normalizedHost = hostname.lowercased()

        guard let existing = hosts.first(where: {
            $0.hostname == normalizedHost &&
            $0.port == port
        }) else {
            return .unknown
        }

        return existing.fingerprint == fingerprint
            ? .trusted
            : .changed
    }

    // MARK: - Trust Host

    func trust(
        hostname: String,
        port: Int,
        fingerprint: String
    ) throws {
        let normalizedHost = hostname.lowercased()

        let newHost = TrustedHost(
            hostname: normalizedHost,
            port: port,
            fingerprint: fingerprint,
            trustedDate: Date()
        )

        var updatedHosts = hosts

        updatedHosts.removeAll {
            $0.hostname == normalizedHost &&
            $0.port == port
        }

        updatedHosts.append(newHost)

        try save(updatedHosts)
        hosts = updatedHosts
    }

    // MARK: - Remove Trust

    func removeTrust(
        hostname: String,
        port: Int
    ) throws {
        let normalizedHost = hostname.lowercased()

        let updatedHosts = hosts.filter {
            $0.hostname != normalizedHost ||
            $0.port != port
        }

        try save(updatedHosts)
        hosts = updatedHosts
    }

    // MARK: - Storage

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(
                [TrustedHost].self,
                from: data
              ) else {
            return
        }

        hosts = saved
    }

    private func save(_ updatedHosts: [TrustedHost]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys
        ]

        try encoder.encode(updatedHosts).write(
            to: fileURL,
            options: .atomic
        )
    }
}
