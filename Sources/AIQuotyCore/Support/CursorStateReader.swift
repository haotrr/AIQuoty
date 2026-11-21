import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

public struct CursorLocalState: Sendable, Equatable {
    public var accessToken: String
    public var email: String?
    public var membershipType: String?

    public init(accessToken: String, email: String? = nil, membershipType: String? = nil) {
        self.accessToken = accessToken
        self.email = email
        self.membershipType = membershipType
    }

    /// Extracts WorkOS user id from JWT `sub` claim (e.g. `auth0|user_01...` -> `user_01...`).
    public var workosUserID: String? {
        Self.extractUserID(fromJWT: accessToken)
    }

    /// Builds `WorkosCursorSessionToken=<userId>::<accessToken>` cookie header when JWT `sub` is present.
    public var sessionCookieHeader: String? {
        guard let userID = workosUserID, !userID.isEmpty else { return nil }
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)"
    }

    public static func extractUserID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = obj["sub"] as? String, !sub.isEmpty else {
            return nil
        }
        if let pipe = sub.lastIndex(of: "|") {
            let trimmed = String(sub[sub.index(after: pipe)...])
            return trimmed.isEmpty ? sub : trimmed
        }
        return sub
    }
}

public protocol CursorStateReading: Sendable {
    func readLocalState() -> CursorLocalState?
}

public struct NullCursorStateReader: CursorStateReading {
    public init() {}
    public func readLocalState() -> CursorLocalState? { nil }
}

public struct SQLiteCursorStateReader: CursorStateReading {
    public let dbPaths: [String]

    public init(
        dbPaths: [String] = [
            "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            "~/.config/Cursor/User/globalStorage/state.vscdb",
        ]
    ) {
        self.dbPaths = dbPaths
    }

    public func readLocalState() -> CursorLocalState? {
        #if canImport(SQLite3)
        for rawPath in dbPaths {
            let path = (rawPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let state = readSQLite(at: path) {
                return state
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(SQLite3)
    private func readSQLite(at path: String) -> CursorLocalState? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT key, value FROM ItemTable
        WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/cachedEmail', 'cursorAuth/stripeMembershipType');
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var values: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kPtr = sqlite3_column_text(stmt, 0),
                  let vPtr = sqlite3_column_text(stmt, 1) else {
                continue
            }
            let key = String(cString: kPtr)
            let val = String(cString: vPtr).trimmingCharacters(in: .whitespacesAndNewlines)
            if !val.isEmpty {
                values[key] = val
            }
        }
        guard let token = values["cursorAuth/accessToken"],
              Self.isPlaintextJWT(token) else {
            return nil
        }
        return CursorLocalState(
            accessToken: token,
            email: values["cursorAuth/cachedEmail"],
            membershipType: values["cursorAuth/stripeMembershipType"]
        )
    }
    #endif

    /// Newer Cursor builds encrypt `cursorAuth/accessToken` with Safe Storage (`cursor-safe-storage:...`).
    /// AIQuoty never decrypts Safe Storage and only accepts plaintext JWT tokens.
    public static func isPlaintextJWT(_ token: String) -> Bool {
        guard !token.isEmpty, !token.hasPrefix("cursor-safe-storage:") else { return false }
        let parts = token.split(separator: ".")
        return parts.count == 3 && token.hasPrefix("eyJ")
    }
}
