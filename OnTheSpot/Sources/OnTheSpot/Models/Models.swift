import Foundation

enum Speaker: String, Codable, Sendable {
    case you
    case them
}

struct Utterance: Identifiable, Codable, Sendable {
    let id: UUID
    let text: String
    let speaker: Speaker
    let timestamp: Date

    init(text: String, speaker: Speaker, timestamp: Date = .now) {
        self.id = UUID()
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
    }
}

struct KBResult: Identifiable, Sendable {
    let id: UUID
    let text: String
    let sourceFile: String
    let score: Double

    init(text: String, sourceFile: String, score: Double) {
        self.id = UUID()
        self.text = text
        self.sourceFile = sourceFile
        self.score = score
    }
}

struct Suggestion: Identifiable, Sendable {
    let id: UUID
    let text: String
    let timestamp: Date
    let kbHits: [KBResult]

    init(text: String, timestamp: Date = .now, kbHits: [KBResult] = []) {
        self.id = UUID()
        self.text = text
        self.timestamp = timestamp
        self.kbHits = kbHits
    }
}

/// Codable record for JSONL session persistence
struct SessionRecord: Codable {
    let speaker: Speaker
    let text: String
    let timestamp: Date
    let suggestions: [String]?
    let kbHits: [String]?
}
