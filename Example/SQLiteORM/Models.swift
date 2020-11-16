//
//  Item.swift
//  SQLiteORM_Example
//
//  Created by Valo on 2019/5/28.
//  Copyright © 2019 CocoaPods. All rights reserved.
//

import SQLiteORM
import UIKit

struct Item {
    var tableName: String = ""
    var count: UInt64 = 0
    var maxCount: UInt64 = 0
    weak var label: UILabel?

    var dbName: String = ""
    var dbPath: String = ""
    var orm: Orm<Message>
    var db: Database
    var fileSize: UInt64 = 0

    var ftsDbName: String = ""
    var ftsDbPath: String = ""
    var ftsOrm: Orm<Message>
    var ftsDb: Database
    var ftsFileSize: UInt64 = 0

    init(dir: String, tableName: String, dbName: String, ftsDbName: String, label: UILabel, maxCount: UInt64) {
        self.tableName = tableName
        self.maxCount = maxCount
        self.dbName = dbName
        self.ftsDbName = ftsDbName
        self.label = label

        let url = URL(fileURLWithPath: dir).appendingPathComponent(dbName)
        dbPath = url.path
        db = Database(with: dbPath)
        orm = Orm(ormable: Message.self, db: db, table: tableName)

        let ftsUrl = URL(fileURLWithPath: dir).appendingPathComponent(ftsDbName)
        ftsDbPath = ftsUrl.path
        ftsDb = Database(with: ftsDbPath)
        ftsDb.register(OrmEnumerator.self, for: "sqliteorm")
        ftsOrm = Orm(ftsable: Message.self, db: ftsDb, table: tableName)
    }
}

struct Message: Codable {
    var dialog_id: String
    var message_id: UInt64
    var client_message_id: UInt64
    var send_time: UInt64
    var type: Int
    var info: String

    static func mockThousand(with infos: [String], startId: UInt64) -> [Message] {
        var results = [Message]()
        let count: UInt64 = UInt64(infos.count)
        for i in 0 ..< 1000 {
            let id: UInt64 = startId + UInt64(i)
            let now: UInt64 = UInt64(NSDate().timeIntervalSince1970)
            let message = Message(dialog_id: "S-10086", message_id: id, client_message_id: id, send_time: now, type: Int(arc4random_uniform(5)), info: infos[Int(id % count)])
            results.append(message)
        }
        return results
    }
}

extension Message: Ormable {
    static var primaries: [String] = ["message_id"]
}

extension Message: Ftsable {
    static var fts_indexes: [String] = ["info"]
    static var tokenizer: String = "sqliteorm 3"
}
