import SwiftUI

/// Content displayed in the floating overlay panel.
struct OverlayContent: View {
    let suggestions: [Suggestion]
    let currentSuggestion: String
    let isGenerating: Bool
    let volatileThemText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Circle()
                    .fill(isGenerating ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text("On The Spot")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 4)

            // Current "them" speech
            if !volatileThemText.isEmpty {
                Text(volatileThemText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .opacity(0.7)
                    .lineLimit(2)
            }

            // Streaming suggestion
            if !currentSuggestion.isEmpty {
                Text(currentSuggestion)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            // Recent suggestions
            if !suggestions.isEmpty && currentSuggestion.isEmpty {
                Text(suggestions[0].text)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            if suggestions.isEmpty && currentSuggestion.isEmpty && !isGenerating {
                Text("Waiting for conversation...")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }
}
