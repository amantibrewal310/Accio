import Foundation

/// Scores how well a typed query matches a name, Spotlight-style: the
/// query's letters must appear in order, and matches at the start of the
/// name or of its words, and runs of consecutive letters, score higher.
/// Case, accents, spaces and punctuation are ignored ("wifi" finds "Wi-Fi").
enum FuzzyMatch {
    /// Scores from here up are matches from the start of the text.
    static let prefixScore = 900

    /// `nil` when `query` doesn't match `text`; higher is better.
    static func score(_ query: String, in text: String) -> Int? {
        let query = Array(fold(query).filter(\.isLetterOrNumber))
        guard !query.isEmpty else { return 0 }
        let (letters, wordStarts) = letters(of: text)
        guard letters.count >= query.count else { return nil }

        // The whole name, from the start: the best kind of match.
        if letters.starts(with: query) {
            return prefixScore + max(100 - (letters.count - query.count), 0)
        }
        // Otherwise the best of the greedy matches starting at each
        // occurrence of the first letter.
        var best: Int?
        for start in letters.indices where letters[start] == query[0] {
            guard let score = greedyScore(query, letters, wordStarts, from: start) else { break }
            best = max(best ?? score, score)
        }
        return best
    }

    private static func greedyScore(_ query: [Character], _ letters: [Character], _ wordStarts: Set<Int>, from start: Int) -> Int? {
        var score = 0
        var previous: Int?
        var index = start
        for char in query {
            while index < letters.count, letters[index] != char { index += 1 }
            guard index < letters.count else { return nil }
            score += 10
            if wordStarts.contains(index) { score += 20 }
            if let previous {
                score += index == previous + 1 ? 15 : -min(index - previous - 1, 5)
            }
            previous = index
            index += 1
        }
        // Matches from the first letter are best, later ones a little worse.
        return start == 0 ? score + 10 : score - min(start, 10)
    }

    /// The text's letters and digits, folded, and which of them start a
    /// word: after a space or punctuation, or a capital after a lowercase
    /// letter ("iStat Menus", "MacBook").
    private static func letters(of text: String) -> ([Character], Set<Int>) {
        var letters: [Character] = []
        var wordStarts: Set<Int> = []
        var previous: Character?
        for char in text {
            defer { previous = char }
            guard char.isLetterOrNumber else { continue }
            let afterBreak = previous.map { !$0.isLetterOrNumber } ?? true
            let camelHump = char.isUppercase && (previous?.isLowercase ?? false)
            if afterBreak || camelHump { wordStarts.insert(letters.count) }
            letters.append(contentsOf: fold(String(char)))
        }
        return (letters, wordStarts)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
