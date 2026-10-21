import Foundation

/// Where a Claude transcript's session title comes from (shared by every Claude reader; don't
/// re-implement it per reader).
///
/// Claude Code 2.1.27x **stopped writing `ai-title`** (0 of the 91 transcripts from the last 7 days
/// on this machine have one). The session name now lives in two places:
/// - the inline line `{"type":"custom-title","customTitle":"…","sessionId":"…"}`, rewritten before
///   every API request; Desktop's auto-naming and `/rename` both land here, so the latest copy is
///   almost always inside the tail window;
/// - the sidecar `<transcript directory>/custom-title.json` (`{"customTitle":"…"}`): the first
///   inline line sits at a median offset of 189KB, past the 64KB head the indexer reads, so the
///   indexer gets the name from this 45-byte file instead.
///
/// Old sessions may still only have `ai-title`; both are accepted, and a custom title (chosen by the
/// user or Desktop) wins over an auto-generated one.
enum ClaudeSessionTitle {
    /// Title line → (is custom, title); any other line or a blank title → nil
    static func line(_ root: [String: Any]) -> (isCustom: Bool, title: String)? {
        guard let type = root["type"] as? String else { return nil }
        let key: String
        switch type {
        case "custom-title": key = "customTitle"
        case "ai-title": key = "aiTitle"
        default: return nil
        }
        guard let raw = root[key] as? String else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : (type == "custom-title", title)
    }

    /// Sidecar title: `…/<id>.jsonl` → `…/<id>/custom-title.json`. Missing / unparsable / blank → nil.
    /// Reads at most 4KB and costs a single stat when the file is absent, so it is cheap on hot paths.
    static func sidecar(transcriptPath: String) -> String? {
        sidecar(transcriptURL: URL(fileURLWithPath: transcriptPath))
    }

    static func sidecar(transcriptURL: URL) -> String? {
        let file = transcriptURL.deletingPathExtension()
            .appendingPathComponent("custom-title.json")
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? handle.close() }
        guard
            let data = try? handle.read(upToCount: 4096),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let raw = root["customTitle"] as? String
        else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
