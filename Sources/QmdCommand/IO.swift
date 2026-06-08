import Foundation
import ShellKit

// Output goes through `Shell.current` so it is captured by a host (SwiftBash)
// that bound its own sinks — stdlib `print` would bypass them and leak to fd 1.

/// Write a line to the shell's stdout.
func out(_ text: String = "") { Shell.current.stdout(text + "\n") }

/// Write raw text (no trailing newline) to the shell's stdout.
func outRaw(_ text: String) { Shell.current.stdout(text) }

/// Write a line to the shell's stderr.
func warn(_ text: String) { Shell.current.stderr(text + "\n") }
