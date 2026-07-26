import Foundation

/// Removes Tarmac-managed artifacts even when a macOS guest has created
/// directories that the host owner cannot enumerate, such as `.Trashes`.
enum ManagedArtifactRemover {
    static func removeItem(at url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }

        try restoreOwnerAccessRecursively(at: url, fileManager: fileManager)
        try fileManager.removeItem(at: url)
    }

    private static func restoreOwnerAccessRecursively(at url: URL, fileManager: FileManager) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { return }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try fileManager.setAttributes(
            [.posixPermissions: permissions | 0o700],
            ofItemAtPath: url.path
        )

        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        for child in children {
            try restoreOwnerAccessRecursively(at: child, fileManager: fileManager)
        }
    }
}
