import Foundation

/// Local, opt-in-by-evidence phrase learning. No host text, network, raw event
/// history, or unconfirmed Rime composition is ever read or persisted.
struct PersonalPhrase: Codable, Equatable {
    let text: String
    let fullKeys: String
    let initials: String
    var confirmations: Int
}

final class PersonalPhraseLearning {
    private struct Syllable {
        let character: String
        let keys: String
    }

    // Persist one confirmed observation too, otherwise a user who exits the
    // keyboard between uses never reaches the second-confirmation threshold.
    private struct PersistedState: Codable {
        var phrases: [PersonalPhrase]
        var observations: [String: Int]
    }

    static var defaultStorageURL: URL {
        RimePaths.userDirURL.appendingPathComponent("personal-phrases-v1.json")
    }

    private let storageURL: URL
    private(set) var phrases: [PersonalPhrase] = []
    private var pending: [Syllable] = []
    private var observations: [String: Int] = [:]
    private let maxPhrases = 500
    private let maxObservations = 500

    init(storageURL: URL = PersonalPhraseLearning.defaultStorageURL) {
        self.storageURL = storageURL
        guard let data = try? Data(contentsOf: storageURL), data.count <= 256_000 else { return }
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(PersistedState.self, from: data) {
            phrases = Self.validPhrases(state.phrases, limit: maxPhrases)
            observations = Dictionary(uniqueKeysWithValues: state.observations
                .filter { Self.isValidObservation($0.key, $0.value) }
                .sorted { $0.key < $1.key }
                .prefix(maxObservations).map { ($0.key, $0.value) })
        } else if let old = try? decoder.decode([PersonalPhrase].self, from: data) {
            // Migration from the first on-device JSON array; no reset required.
            phrases = Self.validPhrases(old, limit: maxPhrases)
        }
    }

    private static func validPhrases(_ entries: [PersonalPhrase], limit: Int) -> [PersonalPhrase] {
        Array(entries.filter { phrase in
            phrase.text.count >= 2 && phrase.text.count <= 6 &&
            phrase.text.allSatisfy { isHanCharacter(String($0)) } &&
            phrase.fullKeys.count >= 4 && phrase.fullKeys.count <= 18 &&
            phrase.initials.count == phrase.text.count &&
            phrase.confirmations > 0 && phrase.confirmations <= 10_000
        }.prefix(limit))
    }

    private static func isValidObservation(_ key: String, _ count: Int) -> Bool {
        guard count == 1 else { return false }
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        return parts.count == 2 && (2...6).contains(parts[0].count) &&
               parts[0].allSatisfy { isHanCharacter(String($0)) } &&
               (4...18).contains(parts[1].count)
    }

    /// A single *selected and actually committed* ideograph with a uniquely
    /// segmentable tone-free, full Zhuyin syllable is acceptable evidence.
    /// Short initial-only sequences and multi-character Rime commits are NOT.
    func accept(_ event: RimeConfirmedSelection, allowed: Bool) {
        guard allowed,
              Self.isHanCharacter(event.selectedText),
              Self.isFullSyllable(event.rawInputBeforeSelection)
        else {
            cancel()
            return
        }
        guard pending.count < 6 else { cancel(); return }
        pending.append(Syllable(character: event.selectedText,
                                keys: event.rawInputBeforeSelection))
    }

    /// An explicit space/newline while Rime has no active composition is a
    /// phrase boundary. Requiring two identical observations limits mistakes.
    /// We do NOT join arbitrary adjacent host text or guess phrase boundaries.
    @discardableResult
    func finishBoundary(allowed: Bool) -> PersonalPhrase? {
        defer { pending.removeAll() }
        guard allowed, pending.count >= 2, pending.count <= 6 else { return nil }
        let text = pending.map(\.character).joined()
        let full = pending.map(\.keys).joined()
        let initials = pending.compactMap { $0.keys.first }.map(String.init).joined()
        let key = text + "|" + full
        if let idx = phrases.firstIndex(where: { $0.text == text && $0.fullKeys == full }) {
            phrases[idx].confirmations = min(phrases[idx].confirmations + 1, 10_000)
        } else if observations[key] == 1 {
            // The second verified occurrence may happen after a process restart.
            observations.removeValue(forKey: key)
            guard phrases.count < maxPhrases else { save(); return nil }
            phrases.append(PersonalPhrase(text: text, fullKeys: full,
                                          initials: initials, confirmations: 2))
        } else {
            guard observations.count < maxObservations else { return nil }
            observations[key] = 1
            save()
            return nil
        }
        save()
        return phrases.first { $0.text == text && $0.fullKeys == full }
    }

    func suggestions(for rawKeys: String) -> [PersonalPhrase] {
        guard !rawKeys.isEmpty, rawKeys.count <= 24 else { return [] }
        return phrases.filter { $0.fullKeys == rawKeys || $0.initials == rawKeys }
            .sorted {
                if $0.confirmations != $1.confirmations { return $0.confirmations > $1.confirmations }
                return $0.text < $1.text
            }
            .prefix(5).map { $0 }
    }

    /// A confirmed selection of our own candidate is genuine positive feedback.
    func confirmPersonal(_ text: String, input: String) {
        guard let index = phrases.firstIndex(where: {
            $0.text == text && ($0.fullKeys == input || $0.initials == input)
        }) else { return }
        phrases[index].confirmations = min(phrases[index].confirmations + 1, 10_000)
        pending.removeAll()
        save()
    }

    /// Immediate correction of a personal candidate is negative feedback.
    func penalize(_ text: String) {
        guard let index = phrases.firstIndex(where: { $0.text == text }) else { return }
        phrases[index].confirmations -= 1
        if phrases[index].confirmations <= 0 { phrases.remove(at: index) }
        save()
    }

    func forget(_ text: String) {
        phrases.removeAll { $0.text == text }
        observations = observations.filter { !$0.key.hasPrefix(text + "|") }
        save()
    }

    func reset() {
        cancel()
        phrases.removeAll()
        observations.removeAll()
        try? FileManager.default.removeItem(at: storageURL)
    }

    func cancel() { pending.removeAll() }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(PersistedState(phrases: phrases,
                                                               observations: observations))
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Fail closed: learning may be unavailable, typing still works.
            // Never log words or raw key sequences.
        }
    }

    private static func isHanCharacter(_ string: String) -> Bool {
        guard string.unicodeScalars.count == 1, let scalar = string.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3400...0x4DBF).contains(scalar.value)
    }

    /// Reject tone keys, mixed punctuation, partial initials and ambiguous
    /// segment boundaries. A full syllable is 1 initial, optional medial and
    /// optional rhyme, with a required medial/rhyme if there is an initial.
    /// Restrict to one unambiguous no-tone syllable, not several syllables.
    private static func isFullSyllable(_ keys: String) -> Bool {
        guard !keys.isEmpty, keys.count <= 3 else { return false }
        let toneKeys: Set<Character> = ["3", "4", "6", "7"]
        guard !keys.contains(where: { toneKeys.contains($0) }) else { return false }
        let consonants: Set<Character> = Set("1qaz2wsxedcrfvtgbyhn")
        let medials: Set<Character> = Set("ujm")
        let finals: Set<Character> = Set("8i9o0pkl;/.,-")
        var seenInitial = false
        var seenMedial = false
        var seenFinal = false
        for (position, ch) in keys.enumerated() {
            if consonants.contains(ch), position == 0, !seenInitial {
                seenInitial = true
            } else if medials.contains(ch), !seenMedial, !seenFinal {
                seenMedial = true
            } else if finals.contains(ch), !seenFinal {
                seenFinal = true
            } else {
                return false
            }
        }
        return seenMedial || seenFinal
    }
}
