import Foundation
import Observation

@Observable
@MainActor
final class TranscriptStore {
    private(set) var utterances: [Utterance] = []
    var volatileYouText: String = ""
    var volatileThemText: String = ""

    func append(_ utterance: Utterance) {
        utterances.append(utterance)
    }

    func clear() {
        utterances.removeAll()
        volatileYouText = ""
        volatileThemText = ""
    }

    var lastThemUtterance: Utterance? {
        utterances.last(where: { $0.speaker == .them })
    }

    var recentUtterances: [Utterance] {
        Array(utterances.suffix(10))
    }
}
