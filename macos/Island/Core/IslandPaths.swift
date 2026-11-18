import Foundation

public enum IslandPaths {
    public static func directory(_ key: String, fallback: String, home: URL) -> URL {
        if let path = ProcessInfo.processInfo.environment[key], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return home.appendingPathComponent(fallback, isDirectory: true)
    }
}
