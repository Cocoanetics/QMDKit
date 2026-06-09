import ArgumentParser
import Foundation
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
    private func runQmd(_ argv: [String], root: URL) async throws -> String {
        let captured = OutputSink()
        let shell = Shell(
            stdout: captured,
            stderr: .discard,
            environment: Environment(variables: [:], workingDirectory: root.path),
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
