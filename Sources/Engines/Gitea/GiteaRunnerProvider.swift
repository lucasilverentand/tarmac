import CryptoKit
import Foundation

private struct GiteaRunnerRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let prerelease: Bool
    let draft: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease, draft, assets
    }
}

actor GiteaRunnerProvider {
    static let minimumVersion = SemanticVersion(major: 0, minor: 2, patch: 12)

    private let storage: StorageManager
    private let session: URLSession
    private var cachedPath: URL?

    init(storage: StorageManager, session: URLSession = .shared) {
        self.storage = storage
        self.session = session
    }

    func ensureRunner() async throws -> URL {
        if let cachedPath, isInstalled(at: cachedPath) { return cachedPath }

        let release = try await latestRelease()
        let version = SemanticVersion(release.tagName)
        guard let version, version >= Self.minimumVersion else {
            throw GiteaAPIError.unsupportedVersion(release.tagName)
        }
        let destination = storage.rootDirectory
            .appendingPathComponent("runners/gitea/\(release.tagName)", isDirectory: true)
        if isInstalled(at: destination) {
            cachedPath = destination
            return destination
        }

        guard let binaryAsset = release.assets.first(where: Self.isDarwinARM64Asset) else {
            throw GiteaAPIError.noCompatibleRunner
        }
        guard let checksumAsset = release.assets.first(where: Self.isChecksumAsset) else {
            throw GiteaAPIError.missingChecksum
        }

        let (binaryData, binaryResponse) = try await session.data(from: binaryAsset.browserDownloadURL)
        guard (binaryResponse as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw GiteaAPIError.invalidResponse
        }
        let (checksumData, checksumResponse) = try await session.data(from: checksumAsset.browserDownloadURL)
        guard (checksumResponse as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
            let checksumText = String(data: checksumData, encoding: .utf8),
            let expected = Self.checksum(for: binaryAsset.name, in: checksumText)
        else {
            throw GiteaAPIError.missingChecksum
        }

        let actual = SHA256.hash(data: binaryData).map { String(format: "%02x", $0) }.joined()
        guard expected.caseInsensitiveCompare(actual) == .orderedSame else {
            throw GiteaAPIError.checksumMismatch(expected: expected, actual: actual)
        }

        let fm = FileManager.default
        let staging = storage.tmpDirectory.appendingPathComponent(
            "gitea-runner-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let artifact = staging.appendingPathComponent(binaryAsset.name)
        try binaryData.write(to: artifact, options: .atomic)
        let binary = staging.appendingPathComponent("act_runner")

        if binaryAsset.name.hasSuffix(".xz") || binaryAsset.name.hasSuffix(".gz") || binaryAsset.name.hasSuffix(".tgz")
        {
            try extract(artifact: artifact, into: staging)
            guard let discovered = try findBinary(in: staging) else { throw GiteaAPIError.extractionFailed }
            if discovered != binary { try fm.moveItem(at: discovered, to: binary) }
        } else {
            try fm.moveItem(at: artifact, to: binary)
        }

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let runScript = staging.appendingPathComponent("run.sh")
        try "#!/bin/bash\nexec ./act_runner daemon\n".write(to: runScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runScript.path)

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
        cachedPath = destination
        return destination
    }

    private func latestRelease() async throws -> GiteaRunnerRelease {
        let url = URL(string: "https://gitea.com/api/v1/repos/gitea/act_runner/releases/latest")!
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw GiteaAPIError.invalidResponse
        }
        return try JSONDecoder().decode(GiteaRunnerRelease.self, from: data)
    }

    private func isInstalled(at directory: URL) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: directory.appendingPathComponent("act_runner").path)
            && fm.isExecutableFile(atPath: directory.appendingPathComponent("run.sh").path)
    }

    private static func isDarwinARM64Asset(_ asset: GiteaRunnerRelease.Asset) -> Bool {
        let name = asset.name.lowercased()
        return name.contains("darwin") && (name.contains("arm64") || name.contains("aarch64"))
            && !isChecksumAsset(asset)
    }

    private static func isChecksumAsset(_ asset: GiteaRunnerRelease.Asset) -> Bool {
        let name = asset.name.lowercased()
        return name.contains("checksum") || name.contains("sha256")
    }

    private static func checksum(for fileName: String, in manifest: String) -> String? {
        for line in manifest.split(whereSeparator: \Character.isNewline) {
            let parts = line.split(whereSeparator: \Character.isWhitespace)
            guard parts.count >= 2 else { continue }
            let listedName = parts.last.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if listedName == fileName, parts[0].count == 64 { return String(parts[0]) }
        }
        return nil
    }

    private func extract(artifact: URL, into directory: URL) throws {
        let process = Process()
        if artifact.pathExtension == "xz", !artifact.lastPathComponent.contains(".tar.") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xz")
            process.arguments = ["-dc", artifact.path]
            let output = directory.appendingPathComponent("act_runner")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: output)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", artifact.path, "-C", directory.path]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GiteaAPIError.extractionFailed }
    }

    private func findBinary(in directory: URL) throws -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return enumerator?.compactMap { $0 as? URL }.first { url in
            url.lastPathComponent == "act_runner" || url.lastPathComponent.hasPrefix("act_runner-")
        }
    }
}

struct SemanticVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ string: String) {
        let numbers = string.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .prefix(3)
            .compactMap { component in Int(component.prefix(while: \Character.isNumber)) }
        guard numbers.count >= 2 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers.count > 2 ? numbers[2] : 0)
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
