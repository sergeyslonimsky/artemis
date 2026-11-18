import Foundation
import GRDB

public final class AppDatabase: Sendable {
    public let dbWriter: any DatabaseWriter
    public let attachmentsDirectory: URL
    public let apiKeys: any APIKeyStore

    public init(
        _ dbWriter: any DatabaseWriter,
        attachmentsDirectory: URL? = nil,
        apiKeys: any APIKeyStore = KeychainAPIKeyStore()
    ) throws {
        self.dbWriter = dbWriter
        self.apiKeys = apiKeys

        if let attachmentsDirectory = attachmentsDirectory {
            self.attachmentsDirectory = attachmentsDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.attachmentsDirectory = appSupport.appendingPathComponent("Artemis/attachments", isDirectory: true)
        }

        try FileManager.default.createDirectory(at: self.attachmentsDirectory, withIntermediateDirectories: true)
        try migrator.migrate(dbWriter)
        try moveLegacyAPIKeysToKeychain()
        try markInterruptedStreamsFailed()
    }

    /// Shared standard on-disk database instance for the application.
    public static let shared: AppDatabase = {
        do {
            let fileManager = FileManager.default
            let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directoryURL = appSupportURL.appendingPathComponent("Artemis", isDirectory: true)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let databaseURL = directoryURL.appendingPathComponent("artemis.sqlite")
            var config = Configuration()
            config.qos = .userInitiated
            // WAL mode is default for DatabasePool in GRDB
            let dbPool = try DatabasePool(path: databaseURL.path, configuration: config)
            let attachmentsDir = directoryURL.appendingPathComponent("attachments", isDirectory: true)
            return try AppDatabase(dbPool, attachmentsDirectory: attachmentsDir)
        } catch {
            fatalError("Failed to initialize AppDatabase: \(error)")
        }
    }()

    /// In-memory database queue useful for SwiftUI Previews and Unit Tests.
    public static func inMemory() -> AppDatabase {
        do {
            var config = Configuration()
            config.qos = .userInitiated
            let dbQueue = try DatabaseQueue(configuration: config)
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            return try AppDatabase(dbQueue, attachmentsDirectory: tempDir, apiKeys: InMemoryAPIKeyStore())
        } catch {
            fatalError("Failed to initialize in-memory database: \(error)")
        }
    }

    // MARK: - Migrations
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = false
        #endif

        // Migration 1: chats & messages
        migrator.registerMigration("v1_chats_messages") { db in
            try db.execute(sql: """
            CREATE TABLE chats (
                id           TEXT PRIMARY KEY,
                title        TEXT NOT NULL,
                title_source TEXT NOT NULL DEFAULT 'placeholder',
                created_at   INTEGER NOT NULL,
                updated_at   INTEGER NOT NULL
            );

            CREATE TABLE messages (
                id               TEXT PRIMARY KEY,
                chat_id          TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
                role             TEXT NOT NULL,
                content          TEXT NOT NULL,
                reasoning        TEXT NOT NULL DEFAULT '',
                created_at       INTEGER NOT NULL,
                tokens           INTEGER,
                tokens_estimated INTEGER,
                duration_ms      INTEGER
            );

            CREATE INDEX messages_by_chat ON messages(chat_id, created_at);
            CREATE INDEX chats_by_updated ON chats(updated_at DESC);
            """)
        }

        // Migration 2: providers & settings
        migrator.registerMigration("v2_providers_settings") { db in
            try db.execute(sql: """
            CREATE TABLE providers (
                id            TEXT PRIMARY KEY,
                name          TEXT NOT NULL,
                base_url      TEXT NOT NULL,
                default_model TEXT NOT NULL DEFAULT '',
                created_at    INTEGER NOT NULL,
                updated_at    INTEGER NOT NULL
            );

            CREATE TABLE settings (
                id                  INTEGER PRIMARY KEY CHECK (id = 1),
                default_provider_id TEXT REFERENCES providers(id) ON DELETE SET NULL
            );

            INSERT INTO settings (id, default_provider_id) VALUES (1, NULL);
            """)
        }

        // Migration 3: providers api_key & models JSON
        migrator.registerMigration("v3_providers_key_and_models") { db in
            try db.execute(sql: """
            ALTER TABLE providers ADD COLUMN api_key TEXT NOT NULL DEFAULT '';
            ALTER TABLE providers ADD COLUMN models TEXT NOT NULL DEFAULT '[]';
            """)
        }

        // Migration 4: full text search FTS5
        migrator.registerMigration("v4_messages_fts5") { db in
            try db.execute(sql: """
            CREATE VIRTUAL TABLE messages_fts USING fts5(
                content,
                content='messages',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            );

            CREATE TRIGGER messages_fts_insert AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts (rowid, content) VALUES (new.rowid, new.content);
            END;

            CREATE TRIGGER messages_fts_delete AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts (messages_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
            END;

            CREATE TRIGGER messages_fts_update AFTER UPDATE OF content ON messages BEGIN
                INSERT INTO messages_fts (messages_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
                INSERT INTO messages_fts (rowid, content) VALUES (new.rowid, new.content);
            END;

            INSERT INTO messages_fts (rowid, content) SELECT rowid, content FROM messages;
            """)
        }

        // Migration 5: attachments
        migrator.registerMigration("v5_attachments") { db in
            try db.execute(sql: """
            CREATE TABLE attachments (
                id         TEXT PRIMARY KEY,
                message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                filename   TEXT NOT NULL,
                mime       TEXT NOT NULL,
                kind       TEXT NOT NULL CHECK (kind IN ('image', 'document')),
                size       INTEGER NOT NULL,
                created_at INTEGER NOT NULL
            );

            CREATE INDEX attachments_by_message ON attachments(message_id);
            """)
        }

        // Migration 6: presets, system prompt, debug mode
        migrator.registerMigration("v6_presets_and_debug") { db in
            try db.execute(sql: """
            ALTER TABLE settings ADD COLUMN system_prompt TEXT NOT NULL DEFAULT '';

            CREATE TABLE presets (
                id                TEXT PRIMARY KEY,
                title             TEXT NOT NULL,
                system_prompt     TEXT NOT NULL DEFAULT '',
                temperature       REAL,
                top_p             REAL,
                frequency_penalty REAL,
                presence_penalty  REAL,
                created_at        INTEGER NOT NULL,
                updated_at        INTEGER NOT NULL
            );

            ALTER TABLE settings ADD COLUMN default_preset_id TEXT REFERENCES presets(id) ON DELETE SET NULL;
            ALTER TABLE settings ADD COLUMN debug_mode INTEGER NOT NULL DEFAULT 0;
            """)
        }

        // Migration 7: stable message ordering, generation status, per-chat model selection
        migrator.registerMigration("v7_message_status_and_chat_model") { db in
            try db.execute(sql: """
            ALTER TABLE messages ADD COLUMN seq    INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE messages ADD COLUMN status TEXT NOT NULL DEFAULT 'done';
            ALTER TABLE messages ADD COLUMN error  TEXT;

            UPDATE messages SET seq = (
                SELECT COUNT(*) FROM messages m2
                 WHERE m2.chat_id = messages.chat_id
                   AND (m2.created_at < messages.created_at
                        OR (m2.created_at = messages.created_at AND m2.rowid <= messages.rowid))
            );
            CREATE INDEX messages_by_chat_seq ON messages(chat_id, seq);

            -- Placeholders left behind by failed generations before statuses existed
            UPDATE messages SET status = 'failed', error = 'The response was interrupted.'
             WHERE role = 'assistant' AND content = '' AND reasoning = '';

            ALTER TABLE chats ADD COLUMN provider_id TEXT REFERENCES providers(id) ON DELETE SET NULL;
            ALTER TABLE chats ADD COLUMN model       TEXT;
            """)
        }

        // Migration 8: backend metadata on replies, routing settings, provider kinds
        migrator.registerMigration("v8_routing") { db in
            try db.execute(sql: """
            ALTER TABLE messages ADD COLUMN backend      TEXT;
            ALTER TABLE messages ADD COLUMN provider_id  TEXT;
            ALTER TABLE messages ADD COLUMN model        TEXT;
            ALTER TABLE messages ADD COLUMN route_reason TEXT;

            ALTER TABLE chats ADD COLUMN routing_mode TEXT;

            ALTER TABLE settings ADD COLUMN default_model     TEXT;
            ALTER TABLE settings ADD COLUMN routing_mode      TEXT NOT NULL DEFAULT 'auto';
            ALTER TABLE settings ADD COLUMN cloud_policy      TEXT NOT NULL DEFAULT 'always_ask';
            ALTER TABLE settings ADD COLUMN on_device_enabled INTEGER NOT NULL DEFAULT 1;
            ALTER TABLE settings ADD COLUMN on_device_titles  INTEGER NOT NULL DEFAULT 1;

            ALTER TABLE providers ADD COLUMN kind TEXT NOT NULL DEFAULT 'custom';
            """)

            // Existing providers: derive the kind from the endpoint.
            let rows = try Row.fetchAll(db, sql: "SELECT id, base_url FROM providers")
            for row in rows {
                let kind = ProviderKind.infer(fromBaseURL: row["base_url"])
                try db.execute(
                    sql: "UPDATE providers SET kind = ? WHERE id = ?",
                    arguments: [kind.rawValue, row["id"] as String]
                )
            }
        }

        // Migration 9: per-chat consent for automatic cloud use
        migrator.registerMigration("v9_chat_cloud_consent") { db in
            try db.execute(sql: "ALTER TABLE chats ADD COLUMN cloud_allowed INTEGER NOT NULL DEFAULT 0")
        }

        // Migration 10: per-model capabilities from /models (web search via the gateway's tool loop)
        migrator.registerMigration("v10_model_capabilities") { db in
            try db.execute(sql: "ALTER TABLE providers ADD COLUMN model_capabilities TEXT NOT NULL DEFAULT '{}'")
        }

        // Migration 11: personal-data tools (extras on replies, settings toggle)
        migrator.registerMigration("v11_personal_data_tools") { db in
            try db.execute(sql: """
            ALTER TABLE messages ADD COLUMN extras TEXT;
            ALTER TABLE settings ADD COLUMN personal_data_tools INTEGER NOT NULL DEFAULT 1;
            """)
        }

        // Migration 12: per-group switches for on-device tools
        migrator.registerMigration("v12_tool_groups") { db in
            try db.execute(sql: "ALTER TABLE settings ADD COLUMN disabled_tool_groups TEXT NOT NULL DEFAULT ''")
        }

        // Migration 13: OpenRouter "only free models" switch
        migrator.registerMigration("v13_only_free_models") { db in
            try db.execute(sql: "ALTER TABLE providers ADD COLUMN only_free_models INTEGER NOT NULL DEFAULT 0")
        }

        return migrator
    }

    /// API keys used to live in `providers.api_key`; move them to the Keychain and blank the column.
    private func moveLegacyAPIKeysToKeychain() throws {
        try dbWriter.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, api_key FROM providers WHERE api_key <> ''")
            for row in rows {
                let id: String = row["id"]
                let key: String = row["api_key"]
                try apiKeys.setAPIKey(key, for: id)
                try db.execute(sql: "UPDATE providers SET api_key = '' WHERE id = ?", arguments: [id])
            }
        }
    }

    /// A generation can't survive an app restart; anything still marked streaming was interrupted.
    private func markInterruptedStreamsFailed() throws {
        try dbWriter.write { db in
            try db.execute(sql: """
                UPDATE messages SET status = 'failed', error = 'The response was interrupted.'
                 WHERE status = 'streaming'
                """)
        }
    }
}
