import OSLog

enum Log {
    static let feed = Logger(subsystem: "com.feedmine.app", category: "feed")
    static let network = Logger(subsystem: "com.feedmine.app", category: "network")
    static let db = Logger(subsystem: "com.feedmine.app", category: "database")
    static let ui = Logger(subsystem: "com.feedmine.app", category: "ui")
    static let import_ = Logger(subsystem: "com.feedmine.app", category: "import")
}
