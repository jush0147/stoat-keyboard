import Foundation

/// Stable mapping between visible candidate order and the engine's native
/// indices. A locally learned word is NOT a Rime index and must never be
/// passed to selectCandidate / selectCandidateAbsolute.
struct PersonalCandidateChoice {
    let candidate: Candidate
    let nativeIndex: Int?
    let personalInput: String?
}

enum PersonalCandidateFusion {
    static func merge(native: [Candidate], personal: [PersonalPhrase],
                      rawInput: String) -> [PersonalCandidateChoice] {
        guard !rawInput.isEmpty else {
            return native.enumerated().map {
                PersonalCandidateChoice(candidate: $0.element,
                                        nativeIndex: $0.offset, personalInput: nil)
            }
        }
        let nativeTexts = Set(native.map(\.text))
        let learned = personal
            .filter { !nativeTexts.contains($0.text) &&
                      ($0.fullKeys == rawInput || $0.initials == rawInput) }
            .prefix(5)
            .map {
                PersonalCandidateChoice(candidate: Candidate(text: $0.text, comment: "個人詞"),
                                        nativeIndex: nil, personalInput: rawInput)
            }
        let original = native.enumerated().map {
            PersonalCandidateChoice(candidate: $0.element,
                                    nativeIndex: $0.offset, personalInput: nil)
        }
        // Personal words need to be reachable at a glance, not after 200 Rime
        // candidates in the expanded panel.
        return Array(learned) + original
    }
}
