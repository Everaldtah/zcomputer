import Foundation
import ZCore

// ZMemory: the personal library.
//   SQLiteDatabase       — minimal SQLite wrapper (CSQLite), serialised connection
//   SQLiteMemoryStore    — MemoryStore on SQLite: items + embeddings + FTS5/LIKE, hybrid RRF search
//   HashingEmbedder      — deterministic feature-hashing embeddings (always available)
//   ProviderEmbedder     — embeddings through any LLMClient
//   NLEmbedder           — NaturalLanguage sentence embeddings (Apple platforms)
//   Chunker              — ~800-token overlapping chunks on paragraph/sentence boundaries
//   MemoryContextBuilder — the memory block for an agent's system prompt
//   EpisodeRecorder      — summarises finished runs into `episode` items

public enum ZMemoryModule { public static let name = "ZMemory" }
