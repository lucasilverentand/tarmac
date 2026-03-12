import Foundation

struct DiskImageManager: Sendable {
    func createSparseDisk(at url: URL, sizeGB: Int) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw DiskImageError.creationFailed(url)
        }

        let fileHandle = try FileHandle(forWritingTo: url)
        defer { try? fileHandle.close() }

        let sizeBytes = Int64(sizeGB) * 1024 * 1024 * 1024
        let fd = fileHandle.fileDescriptor
        guard ftruncate(fd, off_t(sizeBytes)) == 0 else {
            throw DiskImageError.truncateFailed(url, errno)
        }

        Log.vm.info("Created sparse disk at \(url.path) (\(sizeGB) GB)")
    }

    func cloneDisk(from source: URL, to destination: URL) throws {
        let destDir = destination.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        let result = source.path.withCString { src in
            destination.path.withCString { dst in
                Darwin.clonefile(src, dst, 0)
            }
        }

        if result != 0 {
            Log.vm.warning("clonefile failed (errno \(errno)), falling back to copy")
            try fm.copyItem(at: source, to: destination)
        }

        Log.vm.info("Cloned disk from \(source.lastPathComponent) to \(destination.lastPathComponent)")
    }

    func deleteDisk(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        Log.vm.info("Deleted disk at \(url.path)")
    }
}

enum DiskImageError: LocalizedError {
    case creationFailed(URL)
    case truncateFailed(URL, Int32)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let url):
            "Failed to create disk image at \(url.path)"
        case .truncateFailed(let url, let code):
            "Failed to truncate disk image at \(url.path): errno \(code)"
        }
    }
}
