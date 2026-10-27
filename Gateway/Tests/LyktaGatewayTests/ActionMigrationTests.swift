import Foundation
import Testing
@testable import LyktaGateway

struct ActionMigrationTests {
    @Test(arguments: [false, true])
    func previousGatewayStatementsWorkAfterRebuildingActions(pruned: Bool) throws {
        let db = try Database(path: ":memory:")
        try Schema.migrate(db)
        try db.execute("""
            INSERT INTO devices (id, secret_hash, agent_hash, environment, app_version, created_at) VALUES ('phone', 'secret', 'agent', 'development', '0.13.0', 0);
            INSERT INTO activities (id, device_id, name, phase, title, layout, data, content, revision, delivery, created_at)
              VALUES ('activity', 'phone', 'deploy', 'live', 'Deploy', '{}', '{}', '{}', 1, 'accepted', 0);
            DROP TABLE actions;
            CREATE TABLE actions (
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
            CREATE INDEX device_actions ON actions(device_id, seq);
            """)
        try db.run("INSERT INTO actions (id, device_id, activity_id, button, at) VALUES (?, ?, ?, ?, ?)", "old", "phone", "activity", "retry", 10)
        try db.run("INSERT INTO actions (id, device_id, activity_id, button, at) VALUES (?, ?, ?, ?, ?)", "pruned", "phone", "activity", "retry", 0)
        try db.run("DELETE FROM actions WHERE at < ?", pruned ? 11 : 1)
        try Schema.migrate(db)
        #expect(try db.query("PRAGMA user_version")[0].integer("user_version") == 1)
        #expect(try db.query("SELECT seq FROM actions").map { try $0.integer("seq") } == (pruned ? [] : [1]))
        try db.run("INSERT INTO actions (id, device_id, activity_id, button, at) VALUES (?, ?, ?, ?, ?)", "new", "phone", "activity", "retry", 20)
        try db.run("INSERT INTO actions (id, device_id, activity_id, toggle, is_on, at) VALUES (?, ?, ?, ?, ?, ?)", "toggle", "phone", "activity", "done", true, 21)
        let rows = try db.query("""
            SELECT x.seq, x.button, x.toggle, x.is_on, x.at, a.name FROM actions x JOIN activities a ON a.id = x.activity_id
              WHERE x.device_id = ? AND x.seq > ? ORDER BY x.seq LIMIT ?
            """, "phone", 2, 10)
        #expect(try rows.map { try $0.integer("seq") } == [3, 4])
        #expect(try rows.map { try $0.string("name") } == ["deploy", "deploy"])
        #expect(try db.query("SELECT COALESCE(MAX(seq), 0) AS seq FROM actions WHERE device_id = ?", "phone")[0].integer("seq") == 4)
        try db.run("DELETE FROM actions WHERE at < ?", 21)
        try db.run("""
            DELETE FROM actions WHERE seq IN (SELECT seq FROM (
              SELECT seq, ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY seq DESC) AS n FROM actions) WHERE n > ?)
            """, 1)
        #expect(try db.query("SELECT id FROM actions").map { try $0.string("id") } == ["toggle"])
        try db.execute("""
            INSERT INTO widgets (id, device_id, name, title, layout, data, content, requires, revision, created_at, updated_at)
              VALUES ('widget', 'phone', 'water', 'Water', '{}', '{}', '{}', '0.14.0', 1, 0, 0);
            INSERT INTO actions (id, device_id, widget_id, button, at) VALUES ('widget-tap', 'phone', 'widget', 'drink', 22);
            """)
        #expect(throws: SQLiteError.self) { try db.execute("INSERT INTO actions (id, device_id, button, at) VALUES ('none', 'phone', 'go', 22)") }
        #expect(throws: SQLiteError.self) { try db.execute("INSERT INTO actions (id, device_id, activity_id, widget_id, button, at) VALUES ('both', 'phone', 'activity', 'widget', 'go', 22)") }
        try db.execute("DELETE FROM widgets WHERE id = 'widget'")
        #expect(try db.query("SELECT id FROM actions").map { try $0.string("id") } == ["toggle"])
        try Schema.migrate(db)
        #expect(try db.query("SELECT id FROM actions").map { try $0.string("id") } == ["toggle"])
    }
}
