import Foundation
import Testing

@Suite struct LaunchServicesTestSerializationTests {
    @Test func launchServicesCallersShareOneSerializationBoundary() throws {
        let targetContract = try readRepositoryFile(
            "Tests/KnitNoteCoreTests/ShareExtensionTargetContractTests.swift"
        )
        let sharePresentation = try readRepositoryFile(
            "Tests/KnitNoteCoreTests/PatternShareImportPresentationTests.swift"
        )

        let targetIssues = LaunchServicesGateCoverageAudit.issues(
            in: targetContract,
            scope: .shareExtensionTarget
        )
        let presentationIssues = LaunchServicesGateCoverageAudit.issues(
            in: sharePresentation,
            scope: .patternSharePresentation
        )

        #expect(targetIssues.isEmpty, Comment(rawValue: targetIssues.joined(separator: "\n")))
        #expect(
            presentationIssues.isEmpty,
            Comment(rawValue: presentationIssues.joined(separator: "\n"))
        )
    }

    @Test func sharedGateAllowsOnlyOneConcurrentCriticalSection() async {
        let probe = CriticalSectionProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    await LaunchServicesTestGate.shared.withLock {
                        probe.enter()
                        Thread.sleep(forTimeInterval: 0.002)
                        probe.leave()
                    }
                }
            }
        }

        #expect(probe.maximumConcurrentCount == 1)
    }

    @Test func tokenAuditFindsSpacedCallsAndExecutableInterpolation() {
        let source = #"""
        // NSPredicate (value: true), UTType .png, selector calls, and gate decoys are inert here.
        let inert = "await LaunchServicesTestGate.shared.withLock { UTType.png }"
        await LaunchServicesTestGate.shared.withLock {
            _ = UTType .pdf
        }

        _ = NSPredicate (value: true)
        _ = UTType .png
        _ = try? PatternShareImportAttachmentSelector.indexOfSingleSupportedFile (in: [])
        _ = try? PatternShareImportProviderSelection.select (from: [])
        _ = "\(UTType.png.identifier)"
        """#

        let issues = LaunchServicesGateCoverageAudit.issues(
            in: source,
            scope: .patternSharePresentation
        )

        #expect(issues.filter { $0.contains("ungated NSPredicate") }.count == 1)
        #expect(issues.filter { $0.contains("ungated UTType") }.count == 2)
        #expect(issues.filter { $0.contains("ungated attachment selector") }.count == 1)
        #expect(issues.filter { $0.contains("ungated provider selection") }.count == 1)
        #expect(!issues.contains("no shared actor gate closure found"))
    }
}

private enum LaunchServicesGateCoverageAudit {
    enum Scope {
        case shareExtensionTarget
        case patternSharePresentation
    }

    static func issues(in source: String, scope: Scope) -> [String] {
        let tokens = SwiftSourceTokenLexer.tokenize(source)
        let gateRanges = gateClosureRanges(in: tokens)
        var hazards: [(name: String, offset: Int)] = []

        switch scope {
        case .shareExtensionTarget:
            hazards += tokenOffsets(named: "NSPredicate", in: tokens)
                .map { ("NSPredicate", $0) }
            hazards += sequenceOffsets([".", "evaluate"], in: tokens)
                .map { ("predicate evaluation", $0) }
            hazards += tokenOffsets(named: "UTType", in: tokens)
                .map { ("UTType", $0) }
            hazards += tokenIndices(named: "activationContext", in: tokens)
                .filter { index in
                    index == 0 || tokens[index - 1].text != "func"
                }
                .map { ("activationContext call", tokens[$0].offset) }

            let activationHelper = functionBodyRange(named: "activationContext", in: tokens)
            hazards += tokenOffsets(named: "NSItemProvider", in: tokens)
                .filter { offset in
                    guard let activationHelper else { return true }
                    return !activationHelper.contains(offset)
                }
                .map { ("NSItemProvider", $0) }

        case .patternSharePresentation:
            hazards += sequenceOffsets([
                "PatternShareImportAttachmentSelector", ".", "indexOfSingleSupportedFile",
            ], in: tokens).map { ("attachment selector", $0) }
            hazards += sequenceOffsets([
                "PatternShareImportProviderSelection", ".", "select",
            ], in: tokens).map { ("provider selection", $0) }
            hazards += tokenOffsets(named: "NSPredicate", in: tokens)
                .map { ("NSPredicate", $0) }
            hazards += tokenOffsets(named: "NSItemProvider", in: tokens)
                .map { ("NSItemProvider", $0) }
            hazards += tokenOffsets(named: "UTType", in: tokens)
                .map { ("UTType", $0) }
        }

        var issues = hazards.compactMap { hazard -> String? in
            guard !gateRanges.contains(where: { $0.contains(hazard.offset) }) else {
                return nil
            }
            return "ungated \(hazard.name) at byte \(hazard.offset)"
        }
        if gateRanges.isEmpty {
            issues.append("no shared actor gate closure found")
        }
        return issues.sorted()
    }

    private static func gateClosureRanges(in tokens: [SwiftSourceToken]) -> [Range<Int>] {
        sequenceIndices([
            "await", "LaunchServicesTestGate", ".", "shared", ".", "withLock", "{",
        ], in: tokens).compactMap { startIndex in
            braceRange(openingAt: startIndex + 6, in: tokens)
        }
    }

    private static func functionBodyRange(
        named name: String,
        in tokens: [SwiftSourceToken]
    ) -> Range<Int>? {
        guard let declaration = sequenceIndices(["func", name, "("], in: tokens).first,
              let openBrace = tokens[(declaration + 3)...].firstIndex(where: {
                  $0.text == "{"
              }) else {
            return nil
        }
        return braceRange(openingAt: openBrace, in: tokens)
    }

    private static func braceRange(
        openingAt openIndex: Int,
        in tokens: [SwiftSourceToken]
    ) -> Range<Int>? {
        guard tokens.indices.contains(openIndex), tokens[openIndex].text == "{" else {
            return nil
        }
        var depth = 0
        for index in openIndex..<tokens.count {
            if tokens[index].text == "{" { depth += 1 }
            if tokens[index].text == "}" {
                depth -= 1
                if depth == 0 {
                    return tokens[openIndex].offset..<(tokens[index].offset + 1)
                }
            }
        }
        return nil
    }

    private static func tokenIndices(
        named name: String,
        in tokens: [SwiftSourceToken]
    ) -> [Int] {
        tokens.indices.filter { tokens[$0].text == name }
    }

    private static func tokenOffsets(
        named name: String,
        in tokens: [SwiftSourceToken]
    ) -> [Int] {
        tokenIndices(named: name, in: tokens).map { tokens[$0].offset }
    }

    private static func sequenceOffsets(
        _ pattern: [String],
        in tokens: [SwiftSourceToken]
    ) -> [Int] {
        sequenceIndices(pattern, in: tokens).map { tokens[$0].offset }
    }

    private static func sequenceIndices(
        _ pattern: [String],
        in tokens: [SwiftSourceToken]
    ) -> [Int] {
        guard !pattern.isEmpty, pattern.count <= tokens.count else { return [] }
        return (0...(tokens.count - pattern.count)).filter { start in
            zip(tokens[start..<(start + pattern.count)], pattern).allSatisfy {
                $0.text == $1
            }
        }
    }
}

private struct SwiftSourceToken: Sendable {
    let text: String
    let offset: Int
}

private struct SwiftSourceTokenLexer {
    private let bytes: [UInt8]
    private var index = 0
    private var tokens: [SwiftSourceToken] = []

    private init(source: String) {
        bytes = Array(source.utf8)
    }

    static func tokenize(_ source: String) -> [SwiftSourceToken] {
        var lexer = SwiftSourceTokenLexer(source: source)
        lexer.scanCode()
        return lexer.tokens
    }

    private mutating func scanCode(interpolationDepth initialDepth: Int? = nil) {
        var interpolationDepth = initialDepth

        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0

            if let depth = interpolationDepth, byte == 41 {
                if depth == 1 {
                    index += 1
                    return
                }
                interpolationDepth = depth - 1
                appendSymbol(byte)
                continue
            }
            if interpolationDepth != nil, byte == 40 {
                interpolationDepth! += 1
                appendSymbol(byte)
                continue
            }
            if isWhitespace(byte) {
                index += 1
                continue
            }
            if byte == 47, next == 47 {
                skipLineComment()
                continue
            }
            if byte == 47, next == 42 {
                skipBlockComment()
                continue
            }
            if byte == 34 {
                scanString(hashCount: 0, quoteOffset: index)
                continue
            }
            if byte == 35, let stringStart = rawStringStart(at: index) {
                scanString(hashCount: stringStart.hashCount, quoteOffset: stringStart.quoteOffset)
                continue
            }
            if byte == 96 {
                scanBacktickedIdentifier()
                continue
            }
            if isIdentifierStart(byte) {
                scanIdentifier()
                continue
            }
            appendSymbol(byte)
        }
    }

    private mutating func scanString(hashCount: Int, quoteOffset: Int) {
        let multiline = hasBytes([34, 34, 34], at: quoteOffset)
        let quoteCount = multiline ? 3 : 1
        index = quoteOffset + quoteCount

        while index < bytes.count {
            if isStringTerminator(hashCount: hashCount, quoteCount: quoteCount, at: index) {
                index += quoteCount + hashCount
                return
            }
            if let expressionOffset = interpolationExpressionOffset(
                hashCount: hashCount,
                at: index
            ) {
                index = expressionOffset
                scanCode(interpolationDepth: 1)
                continue
            }
            if hashCount == 0, bytes[index] == 92, index + 1 < bytes.count {
                index += 2
                continue
            }
            index += 1
        }
    }

    private func rawStringStart(at offset: Int) -> (hashCount: Int, quoteOffset: Int)? {
        var cursor = offset
        while cursor < bytes.count, bytes[cursor] == 35 { cursor += 1 }
        guard cursor > offset, cursor < bytes.count, bytes[cursor] == 34 else {
            return nil
        }
        return (cursor - offset, cursor)
    }

    private func interpolationExpressionOffset(hashCount: Int, at offset: Int) -> Int? {
        guard bytes[offset] == 92 else { return nil }
        var cursor = offset + 1
        for _ in 0..<hashCount {
            guard cursor < bytes.count, bytes[cursor] == 35 else { return nil }
            cursor += 1
        }
        guard cursor < bytes.count, bytes[cursor] == 40 else { return nil }
        return cursor + 1
    }

    private func isStringTerminator(
        hashCount: Int,
        quoteCount: Int,
        at offset: Int
    ) -> Bool {
        guard hasBytes(Array(repeating: 34, count: quoteCount), at: offset) else {
            return false
        }
        let hashesStart = offset + quoteCount
        return hasBytes(Array(repeating: 35, count: hashCount), at: hashesStart)
    }

    private mutating func skipLineComment() {
        index += 2
        while index < bytes.count, bytes[index] != 10 { index += 1 }
    }

    private mutating func skipBlockComment() {
        index += 2
        var depth = 1
        while index < bytes.count, depth > 0 {
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if bytes[index] == 47, next == 42 {
                depth += 1
                index += 2
            } else if bytes[index] == 42, next == 47 {
                depth -= 1
                index += 2
            } else {
                index += 1
            }
        }
    }

    private mutating func scanIdentifier() {
        let start = index
        index += 1
        while index < bytes.count, isIdentifierContinuation(bytes[index]) {
            index += 1
        }
        tokens.append(SwiftSourceToken(
            text: String(decoding: bytes[start..<index], as: UTF8.self),
            offset: start
        ))
    }

    private mutating func scanBacktickedIdentifier() {
        let start = index
        index += 1
        let contentStart = index
        while index < bytes.count, bytes[index] != 96 { index += 1 }
        tokens.append(SwiftSourceToken(
            text: String(decoding: bytes[contentStart..<index], as: UTF8.self),
            offset: start
        ))
        if index < bytes.count { index += 1 }
    }

    private mutating func appendSymbol(_ byte: UInt8) {
        tokens.append(SwiftSourceToken(
            text: String(decoding: [byte], as: UTF8.self),
            offset: index
        ))
        index += 1
    }

    private func hasBytes(_ expected: [UInt8], at offset: Int) -> Bool {
        guard offset + expected.count <= bytes.count else { return false }
        return bytes[offset..<(offset + expected.count)].elementsEqual(expected)
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 13 || byte == 32
    }

    private func isIdentifierStart(_ byte: UInt8) -> Bool {
        byte == 95 || (65...90).contains(byte) || (97...122).contains(byte) || byte >= 128
    }

    private func isIdentifierContinuation(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (48...57).contains(byte)
    }
}

private final class CriticalSectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var maximumCount = 0

    var maximumConcurrentCount: Int {
        lock.withLock { maximumCount }
    }

    func enter() {
        lock.withLock {
            activeCount += 1
            maximumCount = max(maximumCount, activeCount)
        }
    }

    func leave() {
        lock.withLock {
            activeCount -= 1
        }
    }
}
