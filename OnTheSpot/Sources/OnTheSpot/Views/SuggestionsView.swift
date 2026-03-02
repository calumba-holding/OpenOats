import SwiftUI

struct SuggestionsView: View {
    let suggestions: [Suggestion]
    let currentSuggestion: String
    let isGenerating: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Streaming suggestion
                if isGenerating || !currentSuggestion.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                                .opacity(isGenerating ? 1 : 0)
                            Text("Generating...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        if !currentSuggestion.isEmpty {
                            Text(currentSuggestion)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentTeal.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Past suggestions
                ForEach(suggestions) { suggestion in
                    SuggestionCard(suggestion: suggestion)
                }

                if suggestions.isEmpty && currentSuggestion.isEmpty && !isGenerating {
                    VStack(spacing: 8) {
                        Text("No suggestions yet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Suggestions appear when the other person speaks about topics in your knowledge base.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(16)
        }
    }
}

private struct SuggestionCard: View {
    let suggestion: Suggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(suggestion.text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            if !suggestion.kbHits.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9))
                    Text(suggestion.kbHits.map(\.sourceFile).joined(separator: ", "))
                        .font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
