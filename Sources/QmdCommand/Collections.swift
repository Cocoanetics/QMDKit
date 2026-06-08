import ArgumentParser
import Foundation
import QMDKit
import ShellKit

// MARK: - Config

/// A named directory of Markdown, indexed under its name as the `source`.
struct Collection: Codable {
    var name: String
    var path: String
    var pattern: String = "**/*.md"
}

/// qmd's on-disk collection registry (`<qmd home>/collections.json`).
struct Config: Codable {
    var collections: [Collection] = []

    static func load(at path: String) -> Config {
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return config
    }

    func save(to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path))
    }

    func collection(named name: String) -> Collection? { collections.first { $0.name == name } }
}

/// The qmd working directory: a local `./.qmd` under the shell's CWD when
/// present (created by `qmd init`), otherwise `$XDG_CACHE_HOME/qmd`.
func qmdHome() -> String {
    let local = Shell.currentDirectory.path + "/.qmd"
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: local, isDirectory: &isDirectory), isDirectory.boolValue {
        return local
    }
    let cache = Shell.current.environment["XDG_CACHE_HOME"] ?? (NSHomeDirectory() + "/.cache")
    return cache + "/qmd"
}

/// Resolve a user path to an absolute file using the collections as roots.
/// Accepts an existing file path, `collection/relative/path`, or a relative
/// path found under any collection root.
func resolveDocument(_ path: String, config: Config) -> String? {
    let manager = FileManager.default
    if manager.fileExists(atPath: path) { return path }
    let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
    if parts.count == 2, let collection = config.collection(named: parts[0]) {
        let candidate = collection.path + "/" + parts[1]
        if manager.fileExists(atPath: candidate) { return candidate }
    }
    for collection in config.collections {
        let candidate = collection.path + "/" + path
        if manager.fileExists(atPath: candidate) { return candidate }
    }
    return nil
}

// MARK: - Commands

extension Qmd {
    /// `qmd collection add|list|remove`.
    struct CollectionCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "collection",
            abstract: "Manage indexed directories.",
            subcommands: [Add.self, List.self, Remove.self])

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Register a directory and index it.")
            @OptionGroup var store: StoreOptions
            @Option(help: "Collection name (default: the directory name).") var name: String?
            @Option(help: "Glob pattern (informational for now; *.md is indexed).") var pattern = "**/*.md"
            @Argument(help: "Directory to add.") var path: String

            func run() async throws {
                let root = Shell.resolve(path).resolvingSymlinksInPath()
                let collectionName = name ?? root.lastPathComponent
                var config = store.loadConfig()
                config.collections.removeAll { $0.name == collectionName }
                config.collections.append(Collection(name: collectionName, path: root.path, pattern: pattern))
                try store.saveConfig(config)

                let vectorStore = try await store.open()
                let files = await authorizedFiles(markdownFiles(in: root))
                warn("indexing '\(collectionName)' (\(files.count) file(s))…")
                let summary = try await vectorStore.sync(files: files, source: collectionName, workspaceDir: root.path)
                out("collection '\(collectionName)' → \(root.path) — "
                    + "indexed \(summary.indexed), \(try vectorStore.count()) chunks total")
            }
        }

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List collections.")
            @OptionGroup var store: StoreOptions
            func run() throws {
                let collections = store.loadConfig().collections
                guard !collections.isEmpty else { warn("no collections"); return }
                for collection in collections { out("\(collection.name)\t\(collection.path)") }
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Remove a collection and prune its chunks.")
            @OptionGroup var store: StoreOptions
            @Argument(help: "Collection name.") var name: String
            func run() async throws {
                var config = store.loadConfig()
                guard config.collection(named: name) != nil else {
                    warn("no such collection: \(name)")
                    throw ExitCode.failure
                }
                config.collections.removeAll { $0.name == name }
                try store.saveConfig(config)
                let pruned = try await store.open().sync(files: [], source: name).removed
                out("removed collection '\(name)' (\(pruned) chunks pruned)")
            }
        }
    }

    /// `qmd update` — re-index every collection.
    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Re-index all collections.")
        @OptionGroup var store: StoreOptions
        func run() async throws {
            let collections = store.loadConfig().collections
            guard !collections.isEmpty else {
                warn("no collections — add one with `qmd collection add`")
                return
            }
            let vectorStore = try await store.open()
            for collection in collections {
                let files = await authorizedFiles(markdownFiles(in: URL(fileURLWithPath: collection.path)))
                let summary = try await vectorStore.sync(files: files, source: collection.name, workspaceDir: collection.path)
                out("\(collection.name): indexed \(summary.indexed), unchanged \(summary.unchanged), removed \(summary.removed)")
            }
            out("— \(try vectorStore.count()) chunks total")
        }
    }

    /// `qmd get <path>` — print a document.
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a document by path.")
        @OptionGroup var store: StoreOptions
        @Flag(name: .long, help: "Prefix each line with its number.") var lineNumbers = false
        @Argument(help: "Document path (collection/relative, or a file path).") var path: String

        func run() async throws {
            guard let resolved = resolveDocument(path, config: store.loadConfig()) else {
                warn("not found: \(path)")
                throw ExitCode.failure
            }
            try await Shell.authorize(URL(fileURLWithPath: resolved))
            let content = try String(contentsOfFile: resolved, encoding: .utf8)
            if lineNumbers {
                for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    out("\(index + 1)\t\(line)")
                }
            } else {
                outRaw(content.hasSuffix("\n") ? content : content + "\n")
            }
        }
    }

    /// `qmd ls [collection]` — list collection files.
    struct Ls: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List files in collections.")
        @OptionGroup var store: StoreOptions
        @Argument(help: "Collection name (optional).") var name: String?

        func run() throws {
            let config = store.loadConfig()
            let collections = name.map { wanted in config.collections.filter { $0.name == wanted } } ?? config.collections
            for collection in collections {
                for file in markdownFiles(in: URL(fileURLWithPath: collection.path)) {
                    let prefix = collection.path + "/"
                    let relative = file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : file
                    out("\(collection.name)/\(relative)")
                }
            }
        }
    }

    /// `qmd init` — create a project-local index under `./.qmd`.
    struct Init: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a local project index (./.qmd).")
        func run() async throws {
            let cwd = Shell.currentDirectory.path
            guard cwd != NSHomeDirectory() else {
                warn("refusing to init in your home directory")
                throw ExitCode.failure
            }
            let local = cwd + "/.qmd"
            try await Shell.authorize(URL(fileURLWithPath: local))
            try FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
            try Config().save(to: local + "/collections.json")
            _ = try SQLiteVectorStore(storage: .file(local + "/index.sqlite"))
            out("initialized local qmd index at \(local)")
        }
    }
}
