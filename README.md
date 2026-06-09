# QMDKit

On-device **semantic + keyword search over Markdown** — a sandboxed shell builtin and a standalone CLI.

QMDKit is a Swift reimplementation inspired by [qmd](https://github.com/tobi/qmd): the same spirit and command surface, but built on [SQLiteKit](https://github.com/Cocoanetics/SQLiteKit) (`vec0` + FTS5) with embeddings from either Apple's on-device **NaturalLanguage** models or any LLM embedding provider supported by [SwiftAgents](https://github.com/Cocoanetics/SwiftAgents).

It's designed to be embedded as a `qmd` builtin in [SwiftBash](https://github.com/Cocoanetics/SwiftBash) — and doubles as a compact, readable example of building a local semantic index that fuses full-text search with a vector database.

## Highlights

- **Hybrid search** — fuses vector similarity (`vec0` cosine KNN) with keyword relevance (FTS5 `bm25`), so you get both meaning *and* exact-term matches.
- **Pluggable embeddings** — on-device Apple `NLContextualEmbedding` by default (no key, no network), or an LLM embedder (e.g. OpenAI) when configured.
- **Provenance** — every hit is a `source:path:start:end` citation; chunks carry their 1-indexed source line span.
- **Incremental indexing** — re-indexing only re-embeds files whose content changed (by hash) and prunes ones that were deleted.
- **Sandbox-aware** — hosted in a shell, every file access is gated through ShellKit's authorization; standalone, it just uses process stdio.

## How it works

```
SQLiteKit        vec0 (sqlite-vec) + FTS5 over the vendored SQLite amalgamation
    │
SwiftAgents      SQLiteVectorStore engine · EmbeddingProvider (NL / OpenAI / …)
    │
QMDKit           the qmd commands ──▶ ShellKit / SwiftBash builtin  ·  qmd executable
```

- **Storage & search** — a single SQLite file backed by SQLiteKit's `vec0` and FTS5 engines.
- **Engine** — SwiftAgents' `SQLiteVectorStore`: Markdown-aware chunking, `vec0` KNN, FTS5 `bm25`, weighted hybrid fusion, provenance, incremental sync.
- **Embeddings** — SwiftAgents' `EmbeddingProvider`: Apple `NLContextualEmbedding` (on-device, Apple platforms) or an LLM client.

## Usage

```sh
# Index a directory of Markdown
qmd index ./notes

# Hybrid search (the default subcommand) — meaning + keywords
qmd "how do I rotate the API key"

qmd search "error code 42"               # keyword only (FTS5)
qmd vsearch "a feline on a windowsill"   # semantic only (vec0)

qmd get notes/ideas.md --line-numbers    # print a document
qmd status                               # index info + embedding backend
```

### Collections

Register directories to re-index them by name:

```sh
qmd collection add ./docs --name docs
qmd collection list
qmd update          # re-index every collection
qmd ls docs         # list a collection's files
```

### Output formats

`--cli` (default, colorized) · `--json` · `--files` (`citation⇥score`, for piping to agents) · `--csv` · `--md` · `--xml`; `-n` sets the result count.

### Index location

A project-local `./.qmd` (created by `qmd init`) when present, otherwise `$XDG_CACHE_HOME/qmd`. Override with `--db <path>`.

## Embeddings

| Backend | When | Notes |
|---|---|---|
| Apple `NLContextualEmbedding` | default (Apple platforms) | on-device, no key, no network |
| OpenAI | `OPENAI_API_KEY` is set | model via `QMD_EMBED_MODEL` (default `text-embedding-3-small`) |

Because the engine is SwiftAgents', any `EmbeddingProvider` it ships (OpenAI, Ollama, …) can drive the index — pin one provider for a mixed-language corpus, since `NLContextualEmbedding` picks a model per script.

## As a SwiftBash builtin

`QmdCommand` exposes `Qmd` as a public `AsyncParsableCommand`, so a ShellKit host registers it like any other builtin via the ParsableCommand bridge:

```swift
import QmdCommand

shell.register(Qmd.self)
```

All output routes through `Shell.current` and every path is gated via `Shell.authorize`, so the *same* command code runs **standalone** (process stdio, no sandbox) and **sandboxed** under SwiftBash.

## A reference implementation

Beyond the CLI, QMDKit is a small worked example of a **local semantic index**: how to combine FTS5 keyword search with a `vec0` vector store, chunk Markdown with line-level provenance, fuse the two rankings into one result set, and keep the index incrementally in sync — all over a single SQLite file.

## Requirements

Swift 6.2+ · macOS 14 / iOS 17 / watchOS 10 (on-device embeddings require `NLContextualEmbedding`). On Linux/Windows/Android the engine compiles and runs against an LLM embedder; the Apple on-device path compiles out.

## Credits

- [qmd](https://github.com/tobi/qmd) — the original, and the inspiration.
- [SQLiteKit](https://github.com/Cocoanetics/SQLiteKit) — `vec0` + FTS5 over the vendored SQLite amalgamation.
- [SwiftAgents](https://github.com/Cocoanetics/SwiftAgents) — the `SQLiteVectorStore` engine and embedding providers.
- [ShellKit](https://github.com/Cocoanetics/ShellKit) — the sandboxed shell runtime and ParsableCommand bridge.
