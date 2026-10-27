import Foundation

/// Small vector helpers for embeddings. Vectors are stored as float32 little-endian blobs.
public enum VectorMath {
    /// float32 little-endian bytes.
    public static func encode(_ vector: [Float]) -> Data {
        var data = Data(count: vector.count * 4)
        data.withUnsafeMutableBytes { raw in
            for (index, value) in vector.enumerated() {
                raw.storeBytes(of: value.bitPattern.littleEndian, toByteOffset: index * 4, as: UInt32.self)
            }
        }
        return data
    }

    /// Inverse of `encode`; trailing bytes that do not make a whole float are ignored.
    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / 4
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            (0..<count).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count) { sum += a[index] * b[index] }
        return sum
    }

    public static func norm(_ vector: [Float]) -> Float {
        var sum: Float = 0
        for value in vector { sum += value * value }
        return sum.squareRoot()
    }

    /// Cosine similarity; 0 when the lengths differ or either vector is all zeros.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let denominator = norm(a) * norm(b)
        guard denominator > 0 else { return 0 }
        return dot(a, b) / denominator
    }

    /// Unit-length copy (the zero vector stays zero).
    public static func normalized(_ vector: [Float]) -> [Float] {
        let length = norm(vector)
        guard length > 0 else { return vector }
        return vector.map { $0 / length }
    }

    /// Cosine between `query` and an encoded blob, without decoding it into an array.
    /// Returns nil when the dimensions differ or the stored vector is all zeros.
    static func cosine(_ query: [Float], queryNorm: Float, blob: UnsafeRawBufferPointer) -> Float? {
        let count = blob.count / 4
        guard count == query.count, count > 0, queryNorm > 0 else { return nil }
        var dot: Float = 0
        var squares: Float = 0
        for index in 0..<count {
            let bits = UInt32(littleEndian: blob.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
            let value = Float(bitPattern: bits)
            dot += value * query[index]
            squares += value * value
        }
        guard squares > 0 else { return nil }
        return dot / (queryNorm * squares.squareRoot())
    }
}

/// Reciprocal-rank fusion (Cormack et al.): score(d) = Σ 1 / (k + rank_i(d)), ranks starting at 1.
public enum RankFusion {
    public static func reciprocalRank<ID: Hashable>(_ rankings: [[ID]], k: Double = 60) -> [(id: ID, score: Double)] {
        var scores: [ID: Double] = [:]
        var bestRank: [ID: Int] = [:]
        var firstSeen: [ID: Int] = [:]
        for ranking in rankings {
            var seen = Set<ID>()
            for (index, id) in ranking.enumerated() where seen.insert(id).inserted {
                scores[id, default: 0] += 1.0 / (k + Double(index + 1))
                bestRank[id] = min(bestRank[id] ?? Int.max, index)
                if firstSeen[id] == nil {
                    let order = firstSeen.count
                    firstSeen[id] = order
                }
            }
        }
        return scores
            .map { (id: $0.key, score: $0.value) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                let rankA = bestRank[a.id] ?? Int.max, rankB = bestRank[b.id] ?? Int.max
                if rankA != rankB { return rankA < rankB }
                return (firstSeen[a.id] ?? Int.max) < (firstSeen[b.id] ?? Int.max)
            }
    }
}
