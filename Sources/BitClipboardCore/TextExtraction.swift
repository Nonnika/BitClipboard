import Foundation

public struct ExtractedToken: Identifiable, Equatable, Hashable {
    public enum Kind: String { case number, link }
    public let kind: Kind
    public let value: String
    public var id: String { kind.rawValue + ":" + value }

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public enum TextExtraction {
    private static let links = try! NSRegularExpression(
        // Parse the host separately: Chinese prose following an ASCII TLD isn't part of it.
        // Unicode remains valid in domain labels, paths, queries and fragments.
        pattern: #"(?i)(?<![A-Z0-9_])(?:https?://|www\.)(?:\[[a-f0-9:.]+\]|(?:[\p{L}\p{N}-]+\.)+(?:xn--[a-z0-9-]+|[a-z]{2,63}|[\p{L}&&[^\p{ASCII}]][\p{L}\p{N}-]*)|localhost|(?:[0-9]{1,3}\.){3}[0-9]{1,3})(?::[0-9]{1,5})?(?:[/?#][^\s<>"'“”‘’，。；：！？、（）【】「」]*)?"#
    )
    private static let numbers = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])[-+−]?[0-9]+(?:[.,][0-9]+)*(?:[%％])?(?![A-Za-z0-9_])"#
    )

    public static func extract(from text: String) -> [ExtractedToken] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var candidates: [(range: NSRange, token: ExtractedToken)] = []
        let linkCandidates = recognizedLinks(in: text)
        candidates.append(contentsOf: linkCandidates)
        for match in numbers.matches(in: text, range: range) {
            // Keep URL ports, path IDs and query parameters inside their link.
            guard !linkCandidates.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }),
                  let substring = Range(match.range, in: text) else { continue }
            candidates.append((match.range, ExtractedToken(kind: .number, value: String(text[substring]))))
        }
        candidates.sort { $0.range.location < $1.range.location }
        var seen = Set<ExtractedToken>()
        return candidates.compactMap { seen.insert($0.token).inserted ? $0.token : nil }
    }

    public static func isStandaloneLink(_ text: String) -> Bool {
        let lower = text.prefix(8).lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") else { return false }
        let candidates = recognizedLinks(in: text)
        return candidates.count == 1 && candidates[0].token.value == text
    }

    private static func recognizedLinks(in text: String) -> [(range: NSRange, token: ExtractedToken)] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return links.matches(in: text, range: range).compactMap { match in
            guard let substring = Range(match.range, in: text) else { return nil }
            let value = trimLink(String(text[substring]))
            let address = value.lowercased().hasPrefix("www.") ? "https://" + value : value
            guard let url = URL(string: address), let host = url.host, !host.isEmpty else { return nil }
            // Only the recognized substring excludes numeric extraction, not following prose.
            return (NSRange(location: match.range.location, length: value.utf16.count),
                    ExtractedToken(kind: .link, value: value))
        }
    }

    private static func trimLink(_ value: String) -> String {
        var result = value
        while let last = result.last {
            if ".,;:!?…".contains(last) { result.removeLast(); continue }
            // Preserve balanced parentheses in URLs, e.g. Wikipedia articles.
            let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
            if let opening = pairs[last],
               result.filter({ $0 == last }).count > result.filter({ $0 == opening }).count {
                result.removeLast()
                continue
            }
            break
        }
        return result
    }
}
