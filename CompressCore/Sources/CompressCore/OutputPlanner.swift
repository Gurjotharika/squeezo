import Foundation

/// Decides where a finished compression goes and moves it there.
public enum OutputPlanner {
    struct Placement {
        var url: URL
        /// The original's place in the Trash, when it was moved there.
        var backup: URL?
    }

    /// Moves `temp` to its final place according to `policy`.
    static func place(
        temp: URL,
        source: URL,
        outputExtension: String,
        policy: OutputPolicy,
        fileManager fm: FileManager = .default
    ) throws -> Placement {
        let name = source.deletingPathExtension().lastPathComponent

        switch policy {
        case .replaceOriginal:
            if outputExtension.lowercased() == source.pathExtension.lowercased() {
                _ = try fm.replaceItemAt(source, withItemAt: temp)
                return Placement(url: source)
            }
            let dest = uniqueURL(
                dir: source.deletingLastPathComponent(), name: name, ext: outputExtension, fileManager: fm)
            try fm.moveItem(at: temp, to: dest)
            try fm.trashItem(at: source, resultingItemURL: nil)
            return Placement(url: dest)

        case .replaceAndTrash:
            var trashed: NSURL?
            try fm.trashItem(at: source, resultingItemURL: &trashed)
            let dest = uniqueURL(
                dir: source.deletingLastPathComponent(), name: name, ext: outputExtension, fileManager: fm)
            do {
                try fm.moveItem(at: temp, to: dest)
            } catch {
                // Never leave the user without their file: put the original back.
                if let trashed { try? fm.moveItem(at: trashed as URL, to: source) }
                throw error
            }
            return Placement(url: dest, backup: trashed as URL?)

        case .suffix(let suffix):
            let dest = uniqueURL(
                dir: source.deletingLastPathComponent(), name: name + suffix, ext: outputExtension, fileManager: fm)
            try fm.moveItem(at: temp, to: dest)
            return Placement(url: dest)

        case .folder(let folder):
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = uniqueURL(dir: folder, name: name, ext: outputExtension, fileManager: fm)
            try fm.moveItem(at: temp, to: dest)
            return Placement(url: dest)
        }
    }

    /// `dir/name.ext`, or `dir/name 2.ext`, `name 3.ext`… if that already exists.
    static func uniqueURL(dir: URL, name: String, ext: String, fileManager fm: FileManager) -> URL {
        func candidate(_ n: Int) -> URL {
            let base = n == 1 ? name : "\(name) \(n)"
            let url = dir.appendingPathComponent(base)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }
        var n = 1
        while fm.fileExists(atPath: candidate(n).path) { n += 1 }
        return candidate(n)
    }
}
