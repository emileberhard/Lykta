enum Schema {
    static let version: Int64 = 1

    private static let addedColumns = [
        (table: "activities", column: "ends_at", type: "INTEGER"),
        (table: "devices", column: "layout_version", type: "TEXT"),
        (table: "devices", column: "attestation_key", type: "TEXT"),
        (table: "devices", column: "notification_authorization", type: "TEXT"),
        (table: "devices", column: "alert_style", type: "TEXT"),
        (table: "devices", column: "notification_token", type: "TEXT"),
        (table: "devices", column: "notification_error", type: "TEXT"),
        (table: "devices", column: "moved_push_token_hash", type: "TEXT"),
        (table: "devices", column: "moved_notification_token_hash", type: "TEXT"),
        (table: "activities", column: "channel_environment", type: "TEXT"),
    ]

    static func migrate(_ db: Database) throws {
        guard let found = try db.query("PRAGMA user_version").first.map({ try $0.integer("user_version") }), found <= version else {
            throw ConfigurationError("The database was written by a newer gateway with an incompatible schema; run that version or restore a backup.")
        }
        if try !db.query("SELECT 1 FROM sqlite_master WHERE name = 'events' AND sql NOT LIKE '%AUTOINCREMENT%'").isEmpty {
            try db.transaction {
                try db.execute("ALTER TABLE events RENAME TO reused_events; DROP INDEX device_events; DROP INDEX event_age;")
                try db.execute(tables)
                try db.execute("INSERT INTO events SELECT * FROM reused_events; DROP TABLE reused_events;")
            }
        }
        try db.execute(tables)
        for added in addedColumns {
            guard try db.query("SELECT 1 FROM pragma_table_info('\(added.table)') WHERE name = ?", added.column).isEmpty else { continue }
            try db.execute("ALTER TABLE \(added.table) ADD COLUMN \(added.column) \(added.type)")
        }
        try db.execute("CREATE UNIQUE INDEX IF NOT EXISTS device_attestation_keys ON devices(attestation_key)")
        try db.execute("PRAGMA user_version = \(version)")
    }

    private static let tables = """
        CREATE TABLE IF NOT EXISTS devices (
          id TEXT PRIMARY KEY,
          secret_hash TEXT NOT NULL UNIQUE,
          agent_hash TEXT NOT NULL UNIQUE,
          environment TEXT NOT NULL CHECK (environment IN ('development', 'production')),
          push_token TEXT,
          bundle_instance TEXT,
          app_version TEXT NOT NULL,
          created_at INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS activities (
          id TEXT PRIMARY KEY,
          device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          phase TEXT NOT NULL CHECK (phase IN ('starting', 'live', 'ending', 'ended')),
          title TEXT NOT NULL,
          layout TEXT NOT NULL,
          data TEXT NOT NULL,
          content TEXT NOT NULL,
          stale_after INTEGER,
          relevance REAL,
          alert TEXT,
          dismiss_at INTEGER,
          revision INTEGER NOT NULL,
          sent_revision INTEGER NOT NULL DEFAULT 0,
          channel TEXT,
          in_flight INTEGER NOT NULL DEFAULT 0,
          last_sent_at INTEGER NOT NULL DEFAULT 0,
          retry_at INTEGER NOT NULL DEFAULT 0,
          failures INTEGER NOT NULL DEFAULT 0,
          delivery TEXT NOT NULL CHECK (delivery IN ('pending', 'accepted', 'throttled', 'unknown', 'failed')),
          error TEXT,
          device_state TEXT,
          created_at INTEGER NOT NULL,
          ended_at INTEGER
        ) STRICT;
        CREATE UNIQUE INDEX IF NOT EXISTS live_activity_names ON activities(device_id, name) WHERE phase IN ('starting', 'live');
        CREATE INDEX IF NOT EXISTS activity_devices ON activities(device_id);
        CREATE TABLE IF NOT EXISTS events (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          id TEXT NOT NULL UNIQUE,
          device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
          activity_id TEXT,
          source TEXT NOT NULL CHECK (source IN ('app', 'gateway')),
          name TEXT NOT NULL,
          at INTEGER NOT NULL,
          received_at INTEGER NOT NULL,
          bytes INTEGER NOT NULL,
          detail TEXT NOT NULL
        ) STRICT;
        CREATE INDEX IF NOT EXISTS device_events ON events(device_id, seq);
        CREATE TABLE IF NOT EXISTS actions (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          id TEXT NOT NULL UNIQUE,
          device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
          activity_id TEXT NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
          button TEXT,
          toggle TEXT,
          is_on INTEGER,
          at INTEGER NOT NULL,
          CHECK ((button IS NULL) != (toggle IS NULL) AND (toggle IS NULL) = (is_on IS NULL))
        ) STRICT;
        CREATE INDEX IF NOT EXISTS device_actions ON actions(device_id, seq);
        CREATE INDEX IF NOT EXISTS event_age ON events(received_at);
        CREATE TABLE IF NOT EXISTS notifications (
          id TEXT PRIMARY KEY,
          device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          request TEXT NOT NULL,
          state TEXT NOT NULL CHECK (state IN ('queued', 'sending', 'sent', 'received', 'failed', 'unknown')),
          token_hash TEXT,
          in_flight INTEGER NOT NULL DEFAULT 0,
          retry_at INTEGER NOT NULL DEFAULT 0,
          failures INTEGER NOT NULL DEFAULT 0,
          error TEXT,
          phone TEXT,
          created_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL
        ) STRICT;
        CREATE UNIQUE INDEX IF NOT EXISTS notification_names ON notifications(device_id, name);
        CREATE TABLE IF NOT EXISTS media (
          id TEXT PRIMARY KEY,
          device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
          hash TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('sound', 'image')),
          content_type TEXT NOT NULL,
          bytes BLOB NOT NULL,
          used_at INTEGER NOT NULL
        ) STRICT;
        CREATE UNIQUE INDEX IF NOT EXISTS media_hashes ON media(device_id, hash);
        CREATE TABLE IF NOT EXISTS invites (
          hash TEXT PRIMARY KEY,
          expires_at INTEGER NOT NULL
        ) STRICT;
        """
}
