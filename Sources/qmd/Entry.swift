import QmdCommand

/// Standalone `qmd` entry point. With no host installed, `Shell.current`
/// lazily resolves to the process-default shell (real stdio, no sandbox), so
/// the very same command code runs unsandboxed here and sandboxed under
/// SwiftBash.
@main
struct Entry {
    static func main() async {
        await Qmd.main()
    }
}
