import Foundation
import GRDB

/// A table row mapped through `Codable` with the database's conventions: snake_case columns,
/// dates as Unix milliseconds, nested values (arrays, sets, structs) as JSON text.
protocol AppRecord: Codable, FetchableRecord, PersistableRecord {}

extension AppRecord {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    static var databaseDateDecodingStrategy: DatabaseDateDecodingStrategy { .millisecondsSince1970 }
    static var databaseDateEncodingStrategy: DatabaseDateEncodingStrategy { .millisecondsSince1970 }
}
