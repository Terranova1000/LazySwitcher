import Foundation

/// A language's dictionary and character statistics, read straight from a
/// memory-mapped file.
///
/// Mapped read-only, so the pages are file-backed, shared and evictable: at rest
/// this costs almost nothing, and there is no parsing at launch.
final class LanguageModel {

    enum LoadError: Error {
        case unreadable
        case badMagic
        case unsupportedVersion(UInt32)
        case truncated
    }

    let language: String
    /// Alphabet size, boundary symbol included.
    let symbolCount: Int

    private let data: Data
    /// Character → index. Read from the file rather than hardcoded, so the model
    /// and its reader cannot disagree about what letter index 7 means.
    private let indexOfCharacter: [Character: Int]
    private let dawgRange: Range<Int>
    private let trigramRange: Range<Int>
    private let quadgramRange: Range<Int>

    /// Word boundary: both the padding before a word and the terminator after it.
    static let boundary = 0
    private static let quantisationScale = 8.0

    // MARK: - Loading

    init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw LoadError.unreadable
        }
        self.data = data
        guard data.count >= 32 else { throw LoadError.truncated }

        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }

        guard data[0] == 0x4C, data[1] == 0x53, data[2] == 0x4D, data[3] == 0x31 else {
            throw LoadError.badMagic
        }
        let version = u32(4)
        guard version == 2 else { throw LoadError.unsupportedVersion(version) }

        let code = u32(8)
        language = String(UnicodeScalar(UInt8((code >> 8) & 0xFF))) +
                   String(UnicodeScalar(UInt8(code & 0xFF)))
        symbolCount = Int(u32(12))

        let alphabetBytes = Int(u32(16))
        let dawgBytes = Int(u32(20))
        let trigramBytes = Int(u32(24))
        let quadgramBytes = Int(u32(28))

        var cursor = 32
        let alphabetStart = cursor; cursor += alphabetBytes
        dawgRange = cursor..<(cursor + dawgBytes); cursor += dawgBytes
        trigramRange = cursor..<(cursor + trigramBytes); cursor += trigramBytes
        quadgramRange = cursor..<(cursor + quadgramBytes); cursor += quadgramBytes
        guard cursor <= data.count else { throw LoadError.truncated }

        var map: [Character: Int] = [:]
        for i in 0..<symbolCount {
            let scalar = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: alphabetStart + i * 4, as: UInt32.self)
            }
            if i != Self.boundary, let unicode = UnicodeScalar(scalar) {
                map[Character(unicode)] = i
            }
        }
        indexOfCharacter = map
    }

    // MARK: - Alphabet

    /// Indices for a word, or nil if any character is outside this alphabet.
    ///
    /// Nil rather than "skip the unknown character": a word with a stray symbol
    /// is not a word of this language, and scoring it as if the symbol were
    /// absent would invent evidence that is not there.
    func indices(of word: String) -> [Int]? {
        var result: [Int] = []
        result.reserveCapacity(word.count)
        for character in word {
            guard let index = indexOfCharacter[character] else { return nil }
            result.append(index)
        }
        return result
    }

    func canRepresent(_ word: String) -> Bool { indices(of: word) != nil }

    // MARK: - Dictionary

    /// Is this an exact word of the language?
    func contains(_ word: String) -> Bool {
        guard let indices = indices(of: word), !indices.isEmpty else { return false }
        return walk(indices)?.isFinal ?? false
    }

    /// Could this be the start of some word? Used for early estimates.
    func isPrefix(_ word: String) -> Bool {
        guard let indices = indices(of: word) else { return false }
        if indices.isEmpty { return true }
        return walk(indices) != nil
    }

    private struct Landing { let isFinal: Bool }

    private func walk(_ indices: [Int]) -> Landing? {
        data.withUnsafeBytes { raw -> Landing? in
            let base = raw.baseAddress!.advanced(by: dawgRange.lowerBound)
            let edgeCount = base.loadUnaligned(as: UInt32.self)
            let edges = base.advanced(by: 4)

            var position = 0                 // корень всегда по нулевому смещению
            var final = false
            for symbol in indices {
                var found = false
                var i = position
                while i < Int(edgeCount) {
                    let edge = edges.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                    let edgeSymbol = Int(edge & 0x3F)
                    let isLast = edge & (1 << 26) != 0
                    if edgeSymbol == symbol {
                        position = Int((edge >> 6) & 0xF_FFFF)
                        final = edge & (1 << 27) != 0
                        found = true
                        break
                    }
                    if isLast { break }
                    i += 1
                }
                guard found else { return nil }
            }
            return Landing(isFinal: final)
        }
    }

    // MARK: - Character statistics

    /// log P(word), summed over the 4-gram model, terminator included.
    ///
    /// The terminator is what encodes "Russian words do not end in ъ" and
    /// "English words hardly ever end in q". Dropping it makes a fragment score
    /// as well as a whole word.
    func logProbability(of word: String) -> Double? {
        guard let indices = indices(of: word) else { return nil }
        return logProbability(indices: indices)
    }

    func logProbability(indices: [Int]) -> Double {
        var total = 0.0
        var c1 = Self.boundary, c2 = Self.boundary, c3 = Self.boundary
        for symbol in indices {
            total += quadLogProbability(c1, c2, c3, symbol)
            c1 = c2; c2 = c3; c3 = symbol
        }
        total += quadLogProbability(c1, c2, c3, Self.boundary)
        return total
    }

    /// Cheap running estimate for the in-progress word, from the trigram table —
    /// small enough to sit in L1 cache.
    func trigramLogProbability(_ a: Int, _ b: Int, _ c: Int) -> Double {
        let index = (a * symbolCount + b) * symbolCount + c
        return -quantised(trigramRange, index) / Self.quantisationScale
    }

    private func quadLogProbability(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Double {
        let index = ((a * symbolCount + b) * symbolCount + c) * symbolCount + d
        return -quantised(quadgramRange, index) / Self.quantisationScale
    }

    private func quantised(_ range: Range<Int>, _ index: Int) -> Double {
        let offset = range.lowerBound + index
        guard offset < range.upperBound else { return Double(UInt8.max) }
        return Double(data[offset])
    }
}
