import Foundation

public protocol FileSystemReading: Sendable {
    func fileExists(at path: String) -> Bool
    func readData(at path: String) throws -> Data
    func readUTF8(at path: String) throws -> String
    func listFiles(at path: String, recursive: Bool) throws -> [String]
}

public struct LocalFileSystem: FileSystemReading {
    public init() {}

    public func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: expand(path))
    }

    public func readData(at path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: expand(path)))
    }

    public func readUTF8(at path: String) throws -> String {
        String(data: try readData(at: path), encoding: .utf8) ?? ""
    }

    public func listFiles(at path: String, recursive: Bool) throws -> [String] {
        let root = expand(path)
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        if !recursive {
            return (try FileManager.default.contentsOfDirectory(atPath: root)).map { root + "/" + $0 }
        }
        let url = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return []
        }
        var paths: [String] = []
        for case let fileURL as URL in enumerator {
            paths.append(fileURL.path)
        }
        return paths
    }

    private func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

public struct MemoryFileSystem: FileSystemReading {
    public var files: [String: Data]

    public init(files: [String: Data] = [:]) {
        self.files = files
    }

    public func fileExists(at path: String) -> Bool {
        files[normalize(path)] != nil
    }

    public func readData(at path: String) throws -> Data {
        guard let data = files[normalize(path)] else {
            throw ProviderError.notConfigured("文件不存在：\(path)")
        }
        return data
    }

    public func readUTF8(at path: String) throws -> String {
        String(data: try readData(at: path), encoding: .utf8) ?? ""
    }

    public func listFiles(at path: String, recursive: Bool) throws -> [String] {
        let prefix = normalize(path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return files.keys.filter { key in
            let n = normalize(key)
            if recursive {
                return n.hasPrefix(prefix)
            }
            let parent = (n as NSString).deletingLastPathComponent
            return parent == prefix || parent.hasSuffix("/" + prefix)
        }.sorted()
    }

    private func normalize(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
