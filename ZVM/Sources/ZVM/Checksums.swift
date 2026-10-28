import CryptoKit
import Foundation
import ZCore

/// Checksum files and file hashing.
///
/// Distributions publish their sums in four styles (`images.json` `checksum.style`, research finding 3):
/// * `gnu`: `hex  name` / `hex *name` (Debian, Ubuntu, Arch, openSUSE, AlmaLinux, Kali, ...);
/// * `bsd`: `SHA256 (name) = hex`, often inside a PGP clear-signed file (Fedora `*-CHECKSUM`, Rocky `CHECKSUM`);
/// * `bare`: only the hash (Alpine `*.sha512`);
/// * `api-json`: the `sha_sum` field of a JSON document (Pop!_OS build API).
/// openSUSE's `*-Current.iso.sha256` names the `…-SnapshotYYYYMMDD-Media.iso` file the alias redirects to.
public enum Checksums {
    public enum Algorithm: String, Codable, Sendable, Hashable {
        case sha256, sha512

        /// Length of the lowercase hex digest.
        public var hexLength: Int { self == .sha256 ? 64 : 128 }
        public var displayName: String { self == .sha256 ? "SHA-256" : "SHA-512" }
    }

    public enum Style: String, Codable, Sendable, Hashable {
        case gnu, bsd, bare
        case apiJSON = "api-json"
    }

    /// One line of a sums file.
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var hex: String
    }

    /// Fetches a sums file (injectable for tests).
    public typealias Fetch = @Sendable (URL) async throws -> Data

    /// `URLSession.shared` GET; non-2xx answers are errors.
    public static let urlSessionFetch: Fetch = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ZError.http(status: http.statusCode, body: "checksum file \(url.absoluteString)")
        }
        return data
    }

    // MARK: Parsing

    /// GNU (`hex  name`, `hex *name`, `hex  ./name`) and BSD (`ALGO (name) = hex`) lines, in file order. Comments,
    /// PGP armour headers and signature blocks are skipped.
    public static func entries(in text: String) -> [Entry] {
        var out: [Entry] = []
        var inSignature = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN PGP SIGNATURE") { inSignature = true; continue }
            if line.hasPrefix("-----END PGP SIGNATURE") { inSignature = false; continue }
            guard !inSignature, !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("-----") else { continue }
            if let entry = bsdEntry(line) ?? gnuEntry(line) { out.append(entry) }
        }
        return out
    }

    /// File name → lowercase hex (GNU and BSD lines; the last line for a name wins).
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for entry in entries(in: text) { out[entry.name] = entry.hex }
        return out
    }

    static func gnuEntry(_ line: String) -> Entry? {
        let fields = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count == 2 else { return nil }
        let hex = fields[0].lowercased()
        guard isHex(hex) else { return nil }
        var name = fields[1].trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("*") { name.removeFirst() }
        if name.hasPrefix("./") { name.removeFirst(2) }
        guard !name.isEmpty else { return nil }
        return Entry(name: name, hex: hex)
    }

    static func bsdEntry(_ line: String) -> Entry? {
        guard let open = line.range(of: " ("),
              let close = line.range(of: ") = ", options: .backwards) ?? line.range(of: ")= ", options: .backwards),
              open.upperBound <= close.lowerBound else { return nil }
        let tag = line[line.startIndex..<open.lowerBound]
        guard !tag.isEmpty, tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        let name = String(line[open.upperBound..<close.lowerBound])
        let hex = line[close.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, isHex(hex) else { return nil }
        return Entry(name: name, hex: hex)
    }

    static func isHex(_ s: String) -> Bool {
        s.count >= 32 && s.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// A file holding only a hash (optionally followed by one file name).
    public static func bareHash(in text: String, algorithm: Algorithm) -> String? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard let first = tokens.first, tokens.count <= 2 else { return nil }
        let hex = first.lowercased()
        guard hex.count == algorithm.hexLength, isHex(hex) else { return nil }
        return hex
    }

    /// The `sha_sum` value anywhere in a JSON document (Pop!_OS build API).
    public static func apiJSONHash(in data: Data, algorithm: Algorithm) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let value = findString(forKey: "sha_sum", in: object) else { return nil }
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return hex.count == algorithm.hexLength && isHex(hex) ? hex : nil
    }

    private static func findString(forKey key: String, in object: Any) -> String? {
        if let dict = object as? [String: Any] {
            if let value = dict[key] as? String { return value }
            for name in dict.keys.sorted() {
                if let child = dict[name], let found = findString(forKey: key, in: child) { return found }
            }
        } else if let array = object as? [Any] {
            for child in array {
                if let found = findString(forKey: key, in: child) { return found }
            }
        }
        return nil
    }

    /// The expected digest of `fileName` in a sums document of the given style. Lookup order: `lookupName`, the
    /// exact file name, the openSUSE `-Current` → `-Snapshot…` alias, the only entry of the right length, a bare hash.
    public static func expectedHash(in data: Data, style: Style, fileName: String, lookupName: String? = nil,
                                    algorithm: Algorithm) -> String? {
        if style == .apiJSON { return apiJSONHash(in: data, algorithm: algorithm) }
        let text = String(decoding: data, as: UTF8.self)
        let usable = entries(in: text).filter { $0.hex.count == algorithm.hexLength }
        if let lookupName, let hit = usable.last(where: { $0.name == lookupName }) { return hit.hex }
        if let hit = usable.last(where: { $0.name == fileName }) { return hit.hex }
        if let hit = currentAliasMatch(fileName: fileName, entries: usable) { return hit.hex }
        if usable.count == 1, let only = usable.first { return only.hex }
        if usable.isEmpty { return bareHash(in: text, algorithm: algorithm) }
        return nil
    }

    /// openSUSE: `<prefix>-Current<suffix>` is listed as `<prefix>-Snapshot<date>-Media<suffix>` (exactly one match).
    static func currentAliasMatch(fileName: String, entries: [Entry]) -> Entry? {
        guard let range = fileName.range(of: "-Current") else { return nil }
        let prefix = String(fileName[fileName.startIndex..<range.lowerBound]) + "-"
        let suffix = String(fileName[range.upperBound...])
        let candidates = entries.filter { $0.name.hasPrefix(prefix) && $0.name.hasSuffix(suffix) && $0.name.contains("Snapshot") }
        return candidates.count == 1 ? candidates.first : nil
    }

    // MARK: Expectation

    /// The digest a download must have: from the distribution's sums file when it can be read and lists the file,
    /// otherwise the value embedded in the catalogue.
    public static func expectation(for image: CatalogImage, fetch: Fetch = urlSessionFetch) async -> ChecksumExpectation {
        let checksum = image.checksum
        let embedded = checksum.value.lowercased()
        guard let sumsURL = checksum.url else {
            return ChecksumExpectation(algorithm: checksum.algo, hex: embedded, source: .catalogue(reason: "no checksum file"))
        }
        do {
            let data = try await fetch(sumsURL)
            if let hex = expectedHash(in: data, style: checksum.style, fileName: image.fileName,
                                      lookupName: checksum.lookupName, algorithm: checksum.algo) {
                return ChecksumExpectation(algorithm: checksum.algo, hex: hex, source: .sumsFile(sumsURL))
            }
            return ChecksumExpectation(algorithm: checksum.algo, hex: embedded,
                                       source: .catalogue(reason: "\(sumsURL.lastPathComponent) does not list \(image.fileName)"))
        } catch {
            return ChecksumExpectation(algorithm: checksum.algo, hex: embedded,
                                       source: .catalogue(reason: "\(sumsURL.lastPathComponent) could not be read"))
        }
    }

    // MARK: Hashing

    /// Lowercase hex digest of a file, read in 8 MiB chunks.
    public static func hexDigest(of url: URL, algorithm: Algorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        switch algorithm {
        case .sha256:
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return Bytes.hex(hasher.finalize())
        case .sha512:
            var hasher = SHA512()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return Bytes.hex(hasher.finalize())
        }
    }

    /// Hex digest of in-memory data.
    public static func hexDigest(of data: Data, algorithm: Algorithm) -> String {
        switch algorithm {
        case .sha256: return Bytes.hex(SHA256.hash(data: data))
        case .sha512: return Bytes.hex(SHA512.hash(data: data))
        }
    }
}

/// The digest a download is checked against, and where it came from.
public struct ChecksumExpectation: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// The distribution's sums file, read at download time.
        case sumsFile(URL)
        /// The value in the bundled catalogue (the sums file was unreachable or did not list the file).
        case catalogue(reason: String)
    }

    public var algorithm: Checksums.Algorithm
    public var hex: String
    public var source: Source

    public init(algorithm: Checksums.Algorithm, hex: String, source: Source) {
        self.algorithm = algorithm; self.hex = hex; self.source = source
    }

    /// "SHA-512 from SHA512SUMS" / "SHA-256 from the built-in catalogue (CHECKSUM could not be read)".
    public var summary: String {
        switch source {
        case .sumsFile(let url): return "\(algorithm.displayName) from \(url.lastPathComponent)"
        case .catalogue(let reason): return "\(algorithm.displayName) from the built-in catalogue (\(reason))"
        }
    }
}
