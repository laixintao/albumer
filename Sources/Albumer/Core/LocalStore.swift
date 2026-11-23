import Foundation
import CryptoKit

struct CachedLibrary: Codable, Sendable {
    var albums: [Album]
    var nextOffset: Int?
    var updatedAt: Date
}

struct CachedTracks: Codable, Sendable {
    let tracks: [AlbumTrack]
    let updatedAt: Date
}

struct ListeningHistory: Codable, Sendable {
    var albums: [String: Int] = [:]
    var tracks: [String: Int] = [:]
    var session: ListeningCounter? = nil
}

actor LocalStore {
    static let shared = LocalStore()
    let cacheRoot: URL
    let dataRoot: URL
    private let artworkBudget: Int
    private var writesSincePrune = 0

    init(cacheRoot: URL? = nil, dataRoot: URL? = nil, artworkBudget: Int = 256 * 1024 * 1024) {
        let manager = FileManager.default
        self.cacheRoot = cacheRoot ?? manager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.albumer", isDirectory: true)
        self.dataRoot = dataRoot ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Albumer", isDirectory: true)
        self.artworkBudget = artworkBudget
    }
    static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func accountURL(_ account: String) -> URL {
        cacheRoot.appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(Self.key(account), isDirectory: true)
    }
    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch { /* Cache failures must not prevent playback or network synchronization. */ }
    }
    func library(account: String) -> CachedLibrary? {
        read(CachedLibrary.self, at: accountURL(account).appendingPathComponent("library.json"))
    }
    func saveLibrary(_ library: CachedLibrary, account: String) {
        write(library, to: accountURL(account).appendingPathComponent("library.json"))
    }
    func tracks(album: String, account: String) -> CachedTracks? {
        read(CachedTracks.self, at: accountURL(account).appendingPathComponent("tracks/\(Self.key(album)).json"))
    }
    func saveTracks(_ tracks: [AlbumTrack], album: String, account: String) {
        write(CachedTracks(tracks: tracks, updatedAt: .now), to: accountURL(account).appendingPathComponent("tracks/\(Self.key(album)).json"))
    }
    func history(account: String) -> ListeningHistory {
        read(ListeningHistory.self, at: dataRoot.appendingPathComponent("history/\(Self.key(account)).json")) ?? ListeningHistory()
    }
    func saveHistory(_ history: ListeningHistory, account: String) {
        write(history, to: dataRoot.appendingPathComponent("history/\(Self.key(account)).json"))
    }
    func preferredDeviceID(account: String) -> String? {
        read(String.self, at: accountURL(account).appendingPathComponent("device.json"))
    }
    func savePreferredDeviceID(_ id: String, account: String) {
        write(id, to: accountURL(account).appendingPathComponent("device.json"))
    }
    func removeAccountCache(_ account: String) {
        try? FileManager.default.removeItem(at: accountURL(account))
    }
    private func artworkURL(_ url: URL) -> URL {
        cacheRoot.appendingPathComponent("artwork", isDirectory: true).appendingPathComponent(Self.key(url.absoluteString))
    }
    func artwork(_ url: URL, now: Date = .now) -> Data? {
        let path = artworkURL(url)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let date = attributes[.modificationDate] as? Date, now.timeIntervalSince(date) < 30 * 86400 else {
            try? FileManager.default.removeItem(at: path); return nil
        }
        return try? Data(contentsOf: path)
    }
    func saveArtwork(_ data: Data, url: URL) {
        guard data.count <= 8 * 1024 * 1024 else { return }
        let path = artworkURL(url)
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path, options: .atomic)
            writesSincePrune += 1
            if writesSincePrune == 1 || writesSincePrune >= 8 { pruneArtwork(); writesSincePrune = 1 }
        } catch {}
    }
    private func pruneArtwork() {
        let directory = cacheRoot.appendingPathComponent("artwork", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var size = entries.reduce(0) { $0 + $1.1 }
        for (file, bytes, date) in entries where size > artworkBudget || Date.now.timeIntervalSince(date) > 30 * 86400 {
            try? FileManager.default.removeItem(at: file); size -= bytes
        }
    }
}
