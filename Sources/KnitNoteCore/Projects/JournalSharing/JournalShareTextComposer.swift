import Foundation

public enum JournalShareTextComposer {
    public static func compose(text: String, includeHashtag: Bool) -> String {
        guard includeHashtag else { return text }
        let containsTag = text.split(whereSeparator: \.isWhitespace)
            .contains { $0.caseInsensitiveCompare("#KnitNote") == .orderedSame }
        guard !containsTag else { return text }
        return text.isEmpty ? "#KnitNote" : text + "\n\n#KnitNote"
    }
}
