import ArgumentParser
import Foundation
import Providers
import ShellKit
import Testing
@testable import QmdCommand

@Suite struct QmdBuiltinTests {

    private func tempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qmd-builtin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Run a qmd invocation inside a `Shell` whose stdout is captured and whose
    /// sandbox is rooted at `root` — exactly how SwiftBash would host it.
    @discardableResult
    private func runQmd(_ argv: [String], root: URL, variables: [String: String] = [:]) async throws -> String {
        let captured = OutputSink()
        let shell = Shell(
            stdout: captured,
            stderr: .discard,
            environment: Environment(variables: variables, workingDirectory: root.path),
            sandbox: .rooted(at: root))
        try await Shell.$current.withValue(shell) {
            var command = try Qmd.parseAsRoot(argv)
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        }
        captured.finish()
        return await captured.readAllString()
    }

    @Test func indexAndSearchInsideSandbox() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Cats\n\nThe cat sat on the warm windowsill.\n"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let db = root.appendingPathComponent("idx.sqlite").path

        try await runQmd(["index", root.path, "--db", db], root: root)
        let output = try await runQmd(["search", "--db", db, "cat"], root: root)
        // Output was captured via the shell's sink (not leaked to fd 1) and the
        // in-sandbox file was indexed + found.
        #expect(output.contains("a.md"))
    }

    @Test func queryWithExpansionInsideSandbox() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Cats\n\nThe cat sat on the warm windowsill.\n"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let db = root.appendingPathComponent("idx.sqlite").path

        try await runQmd(["index", root.path, "--db", db], root: root)
        // `query` runs gate → expand → fuse. With no OPENAI_API_KEY the expander
        // is the dependency-free template, so this exercises the pipeline offline
        // and still finds the in-sandbox file.
        let output = try await runQmd(["query", "--db", db, "cat"], root: root)
        #expect(output.contains("a.md"))
        #expect(output.contains("100%"))   // top result normalized to 100%
    }

    @Test func structuredQueryBypassesExpansion() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Cats\n\nThe cat sat on the warm windowsill.\n"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let db = root.appendingPathComponent("idx.sqlite").path

        try await runQmd(["index", root.path, "--db", db], root: root)
        // Caller-typed lex/vec queries skip the expander and go straight to RRF.
        let output = try await runQmd(
            ["query", "--db", db, "--lex", "cat", "--vec", "a feline pet"], root: root)
        #expect(output.contains("a.md"))
    }

    @Test func batchRerankerParsesScores() {
        let scores = OpenAIBatchReranker.parse("1: 90\n2: 30\n[3]: 75\ngarbage line", count: 3)
        #expect(scores.map { ($0 * 100).rounded() } == [90, 30, 75])
    }

    @Test func rerankFlagDegradesWithoutKey() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Cats\n\nThe cat sat on the warm windowsill.\n"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let db = root.appendingPathComponent("idx.sqlite").path

        try await runQmd(["index", root.path, "--db", db], root: root)
        // --rerank with no OPENAI_API_KEY → the reranker is skipped, query still works.
        let output = try await runQmd(["query", "--rerank", "--db", db, "cat"], root: root)
        #expect(output.contains("a.md"))
    }

    @Test func ollamaBackendIsRoleWrapped() async throws {
        let sink = OutputSink()
        let shell = Shell(
            stdout: sink, stderr: .discard,
            environment: Environment(variables: [
                "QMD_EMBED_BACKEND": "ollama",
                "QMD_EMBED_MODEL": "embeddinggemma"
            ], workingDirectory: "/"),
            sandbox: .rooted(at: URL(fileURLWithPath: "/")))
        try await Shell.$current.withValue(shell) {
            // An instruction-tuned model is wrapped so the query/document prompt
            // asymmetry applies; the wrapper still reports the real model so the
            // store's embed-fingerprint is unchanged.
            let provider = StoreOptions.embeddingProvider()
            #expect(provider is InstructionPrefixEmbeddingProvider)
            #expect(provider?.embeddingModelIdentifier == "embeddinggemma")
        }
    }

    /// A small document with a known term on line 5, for renderer assertions.
    private func indexedSample(root: URL) async throws -> String {
        try "# Stream Notes\n\nIntro line.\n\nThe shell reads the input streams.\nMore prose here.\n"
            .write(to: root.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let db = root.appendingPathComponent("idx.sqlite").path
        try await runQmd(["index", root.path, "--db", db], root: root)
        return db
    }

    @Test func cliSearchRendersParityBlocks() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try await indexedSample(root: root)

        let output = try await runQmd(["search", "--db", db, "streams"], root: root)
        #expect(output.contains("files/a.md:5"))               // path:line header
        #expect(output.contains("Title: Stream Notes"))
        #expect(output.contains("Score:"))
        #expect(output.contains("@@ -"))                        // diff-style snippet header
        #expect(output.contains("The shell reads the input streams."))
    }

    @Test func lineNumbersAndFullFlags() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try await indexedSample(root: root)

        let numbered = try await runQmd(["search", "--db", db, "streams", "--line-numbers"], root: root)
        #expect(numbered.contains("5: The shell reads the input streams."))

        let full = try await runQmd(["search", "--db", db, "streams", "--full"], root: root)
        #expect(full.contains("Intro line."))                   // whole document, not a snippet
        #expect(full.contains("More prose here."))
        #expect(!full.contains("@@ -"))
    }

    @Test func structuredFormatsCarrySnippetFields() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try await indexedSample(root: root)

        let json = try await runQmd(["search", "--db", db, "streams", "--json"], root: root)
        #expect(json.contains("\"file\" : \"files/a.md\""))
        #expect(json.contains("\"title\" : \"Stream Notes\""))
        #expect(json.contains("\"snippet\""))
        #expect(json.contains("\"line\" : 5"))

        let csv = try await runQmd(["search", "--db", db, "streams", "--format", "csv"], root: root)
        #expect(csv.hasPrefix("score,file,title,context,line,snippet"))
        #expect(csv.contains("files/a.md"))
    }

    @Test func emptyResultsAreFormatSafe() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try await indexedSample(root: root)

        let none = try await runQmd(["search", "--db", db, "qqqqzz"], root: root)
        #expect(none.contains("No results found."))
        let filtered = try await runQmd(["search", "--db", db, "streams", "--min-score", "2"], root: root)
        #expect(filtered.contains("No results found above minimum score threshold."))
        let json = try await runQmd(["search", "--db", db, "qqqqzz", "--json"], root: root)
        #expect(json.hasPrefix("[]"))
    }

    @Test func cliHeaderHyperlinksToTheFile() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try await indexedSample(root: root)

        // On a terminal (TERM set) the header is an OSC-8 link to the local
        // file; NO_COLOR strips colors but, like the original, leaves links.
        let output = try await runQmd(
            ["search", "--db", db, "streams"], root: root,
            variables: ["TERM": "xterm-256color", "NO_COLOR": "1"])
        #expect(output.contains("\u{1B}]8;;file://"))
        #expect(output.contains("\u{7}files/a.md:5\u{1B}]8;;\u{7}"))
        #expect(!output.contains("\u{1B}[36m"))   // colors stay off

        // QMD_EDITOR_URI overrides the link target, original-style.
        let custom = try await runQmd(
            ["search", "--db", db, "streams"], root: root,
            variables: ["TERM": "xterm-256color", "QMD_EDITOR_URI": "ibash://open/{path}:{line}"])
        #expect(custom.contains("\u{1B}]8;;ibash://open/"))
        #expect(custom.contains(":5\u{7}"))

        // No terminal → no escape sequences at all.
        let plain = try await runQmd(["search", "--db", db, "streams"], root: root)
        #expect(!plain.contains("\u{1B}]8;;"))
    }

    @Test func getSupportsRangeSuffixes() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await indexedSample(root: root)

        // `search` prints `files/a.md:5`; the same identifier pipes back into
        // `get`, with line numbers on by default for follow-up ranges.
        let output = try await runQmd(["get", "files/a.md:5:1"], root: root)
        #expect(output.contains("5: The shell reads the input streams."))
        #expect(!output.contains("More prose here."))

        let plain = try await runQmd(["get", "a.md", "--no-line-numbers"], root: root)
        #expect(plain.contains("# Stream Notes"))
        #expect(!plain.contains("1: #"))
    }

    @Test func deniesAFileOutsideTheSandbox() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try tempDirectory()         // a sibling dir, not under root
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret.md")
        try "top secret notes\n".write(to: secret, atomically: true, encoding: .utf8)
        let db = root.appendingPathComponent("idx.sqlite").path

        // `get` of a path outside the sandbox root must be refused.
        await #expect(throws: (any Error).self) {
            try await self.runQmd(["get", "--db", db, secret.path], root: root)
        }
    }
}
