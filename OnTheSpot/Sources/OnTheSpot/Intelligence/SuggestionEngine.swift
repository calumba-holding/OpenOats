import Foundation
import Observation

/// Generates LLM-powered suggestions based on conversation context and KB results.
@Observable
@MainActor
final class SuggestionEngine {
    private(set) var currentSuggestion: String = ""
    private(set) var suggestions: [Suggestion] = []
    private(set) var isGenerating = false

    private let client = OpenRouterClient()
    private var currentTask: Task<Void, Never>?
    private var lastProcessedUtteranceID: UUID?

    private let transcriptStore: TranscriptStore
    private let knowledgeBase: KnowledgeBase
    private let settings: AppSettings

    init(transcriptStore: TranscriptStore, knowledgeBase: KnowledgeBase, settings: AppSettings) {
        self.transcriptStore = transcriptStore
        self.knowledgeBase = knowledgeBase
        self.settings = settings
    }

    /// Called when a new THEM utterance is finalized.
    func onThemUtterance(_ utterance: Utterance) {
        guard utterance.id != lastProcessedUtteranceID else { return }
        lastProcessedUtteranceID = utterance.id

        // Cancel any in-flight request
        currentTask?.cancel()

        let apiKey = settings.openRouterApiKey
        guard !apiKey.isEmpty else { return }

        isGenerating = true
        currentSuggestion = ""

        currentTask = Task {
            do {
                // Search KB
                let kbResults = knowledgeBase.search(query: utterance.text, topK: 5)

                // Build messages
                let messages = buildMessages(
                    recentUtterances: transcriptStore.recentUtterances,
                    currentQuery: utterance.text,
                    kbResults: kbResults
                )

                // Stream response
                var accumulated = ""
                for try await chunk in await client.streamCompletion(
                    apiKey: apiKey,
                    model: settings.selectedModel,
                    messages: messages
                ) {
                    guard !Task.isCancelled else { break }
                    accumulated += chunk
                    currentSuggestion = accumulated
                }

                if !Task.isCancelled {
                    let suggestion = Suggestion(
                        text: accumulated,
                        kbHits: kbResults
                    )
                    suggestions.insert(suggestion, at: 0)
                    currentSuggestion = ""
                }
            } catch {
                if !Task.isCancelled {
                    print("Suggestion error: \(error)")
                }
            }

            isGenerating = false
        }
    }

    func clear() {
        currentTask?.cancel()
        suggestions.removeAll()
        currentSuggestion = ""
        isGenerating = false
        lastProcessedUtteranceID = nil
    }

    // MARK: - Private

    private func buildMessages(
        recentUtterances: [Utterance],
        currentQuery: String,
        kbResults: [KBResult]
    ) -> [OpenRouterClient.Message] {
        var messages: [OpenRouterClient.Message] = []

        // System prompt
        var systemPrompt = """
        You are a real-time conversation assistant. The user is in a live conversation \
        and needs concise, actionable talking points based on what the other person just said.

        Generate 2-3 brief, natural talking points. Be specific and directly relevant. \
        Each point should be 1-2 sentences max. Use bullet points.
        """

        if !kbResults.isEmpty {
            systemPrompt += "\n\nRelevant context from the knowledge base:\n"
            for result in kbResults {
                systemPrompt += "\n[\(result.sourceFile)]:\n\(result.text)\n"
            }
        }

        messages.append(.init(role: "system", content: systemPrompt))

        // Conversation context
        if !recentUtterances.isEmpty {
            var conversationContext = "Recent conversation:\n"
            for u in recentUtterances {
                let label = u.speaker == .you ? "You" : "Them"
                conversationContext += "\(label): \(u.text)\n"
            }
            messages.append(.init(role: "user", content: conversationContext))
        }

        // Current query
        messages.append(.init(
            role: "user",
            content: "They just said: \"\(currentQuery)\"\n\nGive me talking points to respond with."
        ))

        return messages
    }
}
