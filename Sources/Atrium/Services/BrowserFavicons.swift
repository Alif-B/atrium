import Foundation
import SQLite3

/// Reads the favicon Microsoft Edge itself shows for a site, from Edge's local "Favicons" database (per profile).
/// Edge keeps the file open, so it's copied to a temporary location first and opened read-only. Nothing leaves the Mac.
enum BrowserFavicons {
    private static var edgeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Microsoft Edge")
    }

    /// The largest stored icon for pages on the same scheme + host as `site`.
    static func edgeIcon(for site: URL) -> (data: Data, width: Int, sourceURL: URL?)? {
        guard let scheme = site.scheme, let host = site.host() else { return nil }
        let prefix = "\(scheme)://\(host)/%"
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: edgeRoot.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted { $0 == "Default" ? true : ($1 == "Default" ? false : $0 < $1) }
        var best: (data: Data, width: Int, sourceURL: URL?)?
        for profile in profiles {
            let db = edgeRoot.appendingPathComponent(profile).appendingPathComponent("Favicons")
            guard FileManager.default.fileExists(atPath: db.path), let hit = query(db: db, prefix: prefix) else { continue }
            if hit.width > (best?.width ?? -1) { best = hit }
        }
        return best
    }

    private static func query(db: URL, prefix: String) -> (data: Data, width: Int, sourceURL: URL?)? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("atrium-favicons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? FileManager.default.copyItem(at: db, to: tmp)) != nil else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else { return nil }
        defer { sqlite3_close(handle) }
        let sql = """
            SELECT b.image_data, b.width, f.url FROM icon_mapping m
            JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            JOIN favicons f ON f.id = m.icon_id
            WHERE m.page_url LIKE ?1 AND length(b.image_data) > 0
            ORDER BY b.width DESC, b.last_updated DESC LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)    // SQLITE_TRANSIENT
        sqlite3_bind_text(stmt, 1, prefix, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        let source = sqlite3_column_text(stmt, 2).map { URL(string: String(cString: $0)) } ?? nil
        return (Data(bytes: bytes, count: count), Int(sqlite3_column_int(stmt, 1)), source)
    }
}
