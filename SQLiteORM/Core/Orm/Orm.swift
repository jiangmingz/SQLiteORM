//
//  Orm.swift
//  SQLiteORM
//
//  Created by Valo on 2019/5/7.
//

import Foundation

/// table inspection results
public struct Inspection: OptionSet {
    public let rawValue: UInt8
    /// table exists
    public static let exist = Inspection(rawValue: 1 << 0)

    /// table modified
    public static let tableChanged = Inspection(rawValue: 1 << 1)

    /// index modified
    public static let indexChanged = Inspection(rawValue: 1 << 2)

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

public final class Orm<T: Codable> {
    /// configuration
    public let config: Config

    /// database
    public let db: Database

    /// table name
    public let table: String

    /// property corresponding to the field
    public let properties: [String: PropertyInfo]

    /// Encoder
    public let encoder = OrmEncoder()

    /// Decoder
    public let decoder = OrmDecoder()

    private var created = false

    private var content_table: String? = nil

    private var content_rowid: String? = nil

    private weak var relative: Orm? = nil

    private var tableConfig: Config

    /// initialize orm
    ///
    /// - Parameters:
    ///   - flag: create table immediately? in some sences, table creation  may be delayed
    public init(config: Config, db: Database = Database(.temporary), table: String = "", setup flag: Bool = true) {
        assert(config.type != nil && config.columns.count > 0, "invalid config")

        self.config = config
        self.db = db

        var props = [String: PropertyInfo]()
        let info = try? typeInfo(of: config.type!)
        if info != nil {
            for prop in info!.properties {
                props[prop.name] = prop
            }
        }
        properties = props

        if table.count > 0 {
            self.table = table
        } else {
            self.table = info?.name ?? ""
        }
        tableConfig = Config.factory(self.table, db: db)
        if flag {
            try? setup()
        }
    }

    public convenience init(config: FtsConfig,
                            db: Database = Database(.temporary),
                            table: String = "",
                            content_table: String,
                            content_rowid: String,
                            setup flag: Bool = true) {
        self.init(config: config, db: db, table: table, setup: false)
        self.content_table = content_table
        self.content_rowid = content_rowid
        if flag {
            try? setup()
        }
    }

    public convenience init(config: FtsConfig,
                            relative orm: Orm,
                            content_rowid: String) {
        config.treate()
        if
            let cfg = orm.config as? PlainConfig,
            (cfg.primaries.count == 1 && cfg.primaries.first! == content_rowid) || cfg.uniques.contains(content_rowid),
            Set(config.columns).isSubset(of: Set(cfg.columns)),
            cfg.columns.contains(content_rowid) {
        } else {
            let message =
                """
                 The following conditions must be met:
                 1. The relative ORM is the universal ORM
                 2. The relative ORM has uniqueness constraints
                 3. The relative ORM contains all fields of this ORM
                 4. The relative ORM contains the content_rowid
                """
            assert(false, message)
        }

        let fts_table = "fts_" + orm.table
        self.init(config: config, db: orm.db, table: fts_table, setup: false)
        content_table = orm.table
        self.content_rowid = content_rowid

        // trigger
        let ins_rows = (["rowid"] + config.columns).joined(separator: ",")
        let ins_vals = ([content_rowid] + config.columns).map { "new." + $0 }.joined(separator: ",")
        let del_rows = ([fts_table, "rowid"] + config.columns).joined(separator: ",")
        let del_vals = (["'delete'"] + ([content_rowid] + config.columns).map { "old." + $0 }).joined(separator: ",")

        let ins_tri_name = fts_table + "_insert"
        let del_tri_name = fts_table + "_delete"
        let upd_tri_name = fts_table + "_update"

        let ins_trigger = "CREATE TRIGGER IF NOT EXISTS \(ins_tri_name) AFTER INSERT ON \(orm.table) BEGIN \n"
            + "INSERT INTO \(fts_table) (\(ins_rows)) VALUES (\(ins_vals)); \n"
            + "END;"
        let del_trigger = "CREATE TRIGGER IF NOT EXISTS \(del_tri_name) AFTER DELETE ON \(orm.table) BEGIN \n"
            + "INSERT INTO \(fts_table) (\(del_rows)) VALUES (\(del_vals)); \n"
            + "END;"
        let upd_trigger = "CREATE TRIGGER IF NOT EXISTS \(upd_tri_name) AFTER UPDATE ON \(orm.table) BEGIN \n"
            + "INSERT INTO \(fts_table) (\(del_rows)) VALUES (\(del_vals)); \n"
            + "INSERT INTO \(fts_table) (\(ins_rows)) VALUES (\(ins_vals)); \n"
            + "END;"

        do {
            if !orm.created { try orm.setup() }
            try setup()
            try orm.db.run(ins_trigger)
            try orm.db.run(del_trigger)
            try orm.db.run(upd_trigger)
        } catch {
            print(error)
        }
    }

    /// table creation
    public func setup() throws {
        let ins = inspect()
        try setup(with: ins)
    }

    /// inspect table
    public func inspect() -> Inspection {
        var ins: Inspection = .init()
        let exist = db.exists(table)
        guard exist else {
            return ins
        }
        ins.insert(.exist)

        switch (tableConfig, config) {
            case let (tableConfig as PlainConfig, config as PlainConfig):
                if tableConfig != config {
                    ins.insert(.tableChanged)
                }
                if !tableConfig.isIndexesEqual(config) {
                    ins.insert(.indexChanged)
                }
            case let (tableConfig as FtsConfig, config as FtsConfig):
                if tableConfig != config {
                    ins.insert(.tableChanged)
                }
            default:
                ins.insert([.tableChanged, .indexChanged])
        }
        return ins
    }

    /// create table with inspection
    public func setup(with options: Inspection) throws {
        guard !created else { return }

        let exist = options.contains(.exist)
        let changed = options.contains(.tableChanged)
        let indexChanged = options.contains(.indexChanged)
        let general = config is PlainConfig

        let tempTable = table + "_" + String(describing: NSDate().timeIntervalSince1970)

        if exist && changed {
            try rename(to: tempTable)
        }
        if !exist || changed {
            try createTable()
        }
        if exist && changed && general {
            // NOTE: FTS表请手动迁移数据
            try migrationData(from: tempTable)
        }
        if general && (indexChanged || !exist) {
            try rebuildIndex()
        }
        created = true
    }

    /// rename table
    func rename(to tempTable: String) throws {
        let sql = "ALTER TABLE \(table.quoted) RENAME TO \(tempTable.quoted)"
        try db.run(sql)
    }

    /// create table
    public func createTable() throws {
        var sql = ""
        switch config {
            case let cfg as PlainConfig:
                sql = cfg.createSQL(with: table)
            case let cfg as FtsConfig:
                sql = cfg.createSQL(with: table, content_table: content_table, content_rowid: content_rowid)
            default: break
        }
        try db.run(sql)
    }

    /// migrating data from old table to new table
    func migrationData(from tempTable: String) throws {
        let columnsSet = NSMutableOrderedSet(array: config.columns)
        columnsSet.intersectSet(Set(tableConfig.columns))
        let columns = columnsSet.array as! [String]

        let fields = columns.joined(separator: ",")
        guard fields.count > 0 else {
            return
        }
        let sql = "INSERT INTO \(table.quoted) (\(fields)) SELECT \(fields) FROM \(tempTable.quoted)"
        let drop = "DROP TABLE IF EXISTS \(tempTable.quoted)"
        try db.run(sql)
        try db.run(drop)
    }

    /// rebuild indexes
    func rebuildIndex() throws {
        guard config is PlainConfig else {
            return
        }
        // delete old indexes
        var dropIdxSQL = ""
        let indexesSQL = "SELECT name FROM sqlite_master WHERE type ='index' and tbl_name = \(table.quoted)"
        let array = db.query(indexesSQL)
        for dic in array {
            let name = (dic["name"] as? String) ?? ""
            if !name.hasPrefix("sqlite_autoindex_") {
                dropIdxSQL += "DROP INDEX IF EXISTS \(name.quoted);"
            }
        }
        guard config.indexes.count > 0 else {
            return
        }
        // create new indexes
        let indexName = "orm_index_\(table)"
        let indexesString = config.indexes.joined(separator: ",")
        let createSQL = indexesSQL.count > 0 ? "CREATE INDEX IF NOT EXISTS \(indexName.quoted) on \(table.quoted) (\(indexesString));" : ""
        if indexesSQL.count > 0 {
            if dropIdxSQL.count > 0 {
                try db.run(dropIdxSQL)
            }
            if createSQL.count > 0 {
                try db.run(createSQL)
            }
        }
    }
}