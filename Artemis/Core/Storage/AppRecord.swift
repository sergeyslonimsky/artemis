import Foundation
import GRDB

/// A table row mapped through `Codable` with the database's conventions: snake_case columns,
/// dates as Unix milliseconds, nested values (arrays, sets, structs) as JSON text.
protocol AppRecord: Codable, FetchableRecord, PersistableRecord {}

extension AppRecord {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }

    // GRDB's requirements take the column; same-named properties without it are never called.
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .millisecondsSince1970 }
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .millisecondsSince1970 }
}
