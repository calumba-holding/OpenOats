import Foundation

/// A chunk of text from a knowledge base document.
struct KBChunk: Sendable {
    let text: String
    let sourceFile: String
    let tfidfVector: [String: Double]
}

/// TF-IDF based knowledge base search over a folder of .md/.txt files.
@Observable
@MainActor
final class KnowledgeBase {
    private(set) var chunks: [KBChunk] = []
    private(set) var isIndexed = false
    private(set) var fileCount = 0
    private var idf: [String: Double] = [:]

    func index(folderURL: URL) async {
        // Collect file URLs synchronously to avoid async iterator issues
        let fileURLs = collectFiles(in: folderURL)

        var allChunks: [KBChunk] = []
        var documentFrequency: [String: Int] = [:]
        var files = 0

        for fileURL in fileURLs {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            files += 1

            let fileName = fileURL.lastPathComponent
            let textChunks = chunkText(content, maxWords: 500)

            for chunk in textChunks {
                let tf = termFrequency(chunk)
                allChunks.append(KBChunk(text: chunk, sourceFile: fileName, tfidfVector: tf))
                let uniqueTerms = Set(tf.keys)
                for term in uniqueTerms {
                    documentFrequency[term, default: 0] += 1
                }
            }
        }

        let n = Double(allChunks.count)
        var computedIDF: [String: Double] = [:]
        for (term, df) in documentFrequency {
            computedIDF[term] = log((1.0 + n) / (1.0 + Double(df))) + 1.0
        }
        self.idf = computedIDF
        self.chunks = allChunks
        self.fileCount = files
        self.isIndexed = true
    }

    private nonisolated func collectFiles(in folderURL: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "md" || ext == "txt" {
                urls.append(fileURL)
            }
        }
        return urls
    }

    func search(query: String, topK: Int = 5) -> [KBResult] {
        guard isIndexed, !chunks.isEmpty else { return [] }

        let queryTF = termFrequency(query)
        let queryVec = tfidfVector(tf: queryTF)

        var scored: [(Int, Double)] = []
        for (i, chunk) in chunks.enumerated() {
            let chunkVec = tfidfVector(tf: chunk.tfidfVector)
            let sim = cosineSimilarity(queryVec, chunkVec)
            if sim > 0.01 {
                scored.append((i, sim))
            }
        }

        scored.sort { $0.1 > $1.1 }

        return scored.prefix(topK).map { idx, score in
            let chunk = chunks[idx]
            return KBResult(text: chunk.text, sourceFile: chunk.sourceFile, score: score)
        }
    }

    func clear() {
        chunks.removeAll()
        idf.removeAll()
        isIndexed = false
        fileCount = 0
    }

    // MARK: - Private

    private func chunkText(_ text: String, maxWords: Int) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > maxWords else { return [text.trimmingCharacters(in: .whitespacesAndNewlines)] }

        var result: [String] = []
        var start = 0
        let overlap = maxWords / 5

        while start < words.count {
            let end = min(start + maxWords, words.count)
            let chunk = words[start..<end].joined(separator: " ")
            result.append(chunk)
            start += maxWords - overlap
        }

        return result
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }

    private func termFrequency(_ text: String) -> [String: Double] {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return [:] }
        var freq: [String: Double] = [:]
        for token in tokens {
            freq[token, default: 0] += 1.0
        }
        let count = Double(tokens.count)
        for key in freq.keys {
            freq[key]! /= count
        }
        return freq
    }

    private func tfidfVector(tf: [String: Double]) -> [String: Double] {
        var vec: [String: Double] = [:]
        for (term, tfVal) in tf {
            let idfVal = idf[term] ?? 1.0
            vec[term] = tfVal * idfVal
        }
        return vec
    }

    private func cosineSimilarity(_ a: [String: Double], _ b: [String: Double]) -> Double {
        let allKeys = Set(a.keys).intersection(Set(b.keys))
        guard !allKeys.isEmpty else { return 0.0 }

        var dot = 0.0
        for key in allKeys {
            dot += (a[key] ?? 0) * (b[key] ?? 0)
        }

        let magA = sqrt(a.values.reduce(0) { $0 + $1 * $1 })
        let magB = sqrt(b.values.reduce(0) { $0 + $1 * $1 })

        guard magA > 0 && magB > 0 else { return 0.0 }
        return dot / (magA * magB)
    }
}
