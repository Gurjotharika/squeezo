import Foundation

/// Expands dropped items into a flat list of files.
public enum FileCollector {
    /// Files are kept as given. Folders are searched recursively (hidden files and package
    /// contents are skipped). Duplicates are removed and the first-seen order is kept.
    public static func collect(_ urls: [URL], fileManager fm: FileManager = .default) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            if seen.insert(url.standardizedFileURL.path).inserted { result.append(url) }
        }

        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else {
                append(url)
                continue
            }
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var found: [URL] = []
            while let item = enumerator?.nextObject() as? URL {
                if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    found.append(item)
                }
            }
            found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.forEach(append)
        }
        return result
    }
}
