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
}

private enum LaunchServicesGateCoverageAudit {
    enum Scope {
        case shareExtensionTarget
        case patternSharePresentation
    }

    private static let gateCall = Array(
        "await LaunchServicesTestGate.shared.withLock".utf8
    )

    static func issues(in source: String, scope: Scope) -> [String] {
        let code = codeBytes(from: source)
        let gateRanges = closureRanges(after: gateCall, in: code)
        var hazards: [(name: String, offset: Int)] = []

        switch scope {
        case .shareExtensionTarget:
            hazards += occurrences(of: "NSPredicate(", in: code).map { ("NSPredicate", $0) }
            hazards += occurrences(of: ".evaluate(with:", in: code).map { ("predicate evaluation", $0) }
            hazards += typeOccurrences(in: code)
            hazards += occurrences(of: "activationContext(", in: code)
                .filter { !isFunctionDeclaration(at: $0, in: code) }
                .map { ("activationContext call", $0) }

            let activationHelper = functionBodyRange(named: "activationContext", in: code)
            hazards += occurrences(of: "NSItemProvider(", in: code)
                .filter { offset in
                    guard let activationHelper else { return true }
                    return !activationHelper.contains(offset)
                }
                .map { ("NSItemProvider", $0) }

        case .patternSharePresentation:
            hazards += occurrences(
                of: "PatternShareImportAttachmentSelector.indexOfSingleSupportedFile(",
                in: code
            ).map { ("attachment selector", $0) }
            hazards += occurrences(
                of: "PatternShareImportProviderSelection.select(",
                in: code
            ).map { ("provider selection", $0) }
            hazards += occurrences(of: "NSPredicate(", in: code).map { ("NSPredicate", $0) }
            hazards += occurrences(of: "NSItemProvider(", in: code).map { ("NSItemProvider", $0) }
            hazards += typeOccurrences(in: code)
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

    private static func typeOccurrences(in code: [UInt8]) -> [(name: String, offset: Int)] {
        let dotted = occurrences(of: "UTType.", in: code).map { ("UTType", $0) }
        let initialized = occurrences(of: "UTType(", in: code).map { ("UTType", $0) }
        return dotted + initialized
    }

    private static func closureRanges(after token: [UInt8], in code: [UInt8]) -> [Range<Int>] {
        occurrences(of: token, in: code).compactMap { offset in
            let suffix = code[(offset + token.count)...]
            guard let openBrace = suffix.firstIndex(where: { byte in
                byte != 9 && byte != 10 && byte != 13 && byte != 32
            }), code[openBrace] == 123 else {
                return nil
            }
            var depth = 0
            for index in openBrace..<code.count {
                if code[index] == 123 { depth += 1 }
                if code[index] == 125 {
                    depth -= 1
                    if depth == 0 { return openBrace..<(index + 1) }
                }
            }
            return nil
        }
    }

    private static func functionBodyRange(named name: String, in code: [UInt8]) -> Range<Int>? {
        let declaration = Array("func \(name)(".utf8)
        guard let offset = occurrences(of: declaration, in: code).first,
              let openBrace = code[(offset + declaration.count)...].firstIndex(of: 123) else {
            return nil
        }
        var depth = 0
        for index in openBrace..<code.count {
            if code[index] == 123 { depth += 1 }
            if code[index] == 125 {
                depth -= 1
                if depth == 0 { return openBrace..<(index + 1) }
            }
        }
        return nil
    }

    private static func isFunctionDeclaration(at offset: Int, in code: [UInt8]) -> Bool {
        let prefix = code[max(0, offset - 24)..<offset]
        return String(decoding: prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix("func")
    }

    private static func occurrences(of token: String, in code: [UInt8]) -> [Int] {
        occurrences(of: Array(token.utf8), in: code)
    }

    private static func occurrences(of token: [UInt8], in code: [UInt8]) -> [Int] {
        guard !token.isEmpty, token.count <= code.count else { return [] }
        return (0...(code.count - token.count)).filter { offset in
            code[offset..<(offset + token.count)].elementsEqual(token)
        }
    }

    private static func codeBytes(from source: String) -> [UInt8] {
        var bytes = Array(source.utf8)
        var index = 0
        var blockCommentDepth = 0
        var inLineComment = false
        var inString = false
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0

            if inLineComment {
                if byte == 10 { inLineComment = false } else { bytes[index] = 32 }
            } else if blockCommentDepth > 0 {
                if byte == 47, next == 42 {
                    bytes[index] = 32
                    bytes[index + 1] = 32
                    blockCommentDepth += 1
                    index += 1
                } else if byte == 42, next == 47 {
                    bytes[index] = 32
                    bytes[index + 1] = 32
                    blockCommentDepth -= 1
                    index += 1
                } else if byte != 10 {
                    bytes[index] = 32
                }
            } else if inString {
                if byte != 10 { bytes[index] = 32 }
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    inString = false
                }
            } else if byte == 47, next == 47 {
                bytes[index] = 32
                bytes[index + 1] = 32
                inLineComment = true
                index += 1
            } else if byte == 47, next == 42 {
                bytes[index] = 32
                bytes[index + 1] = 32
                blockCommentDepth = 1
                index += 1
            } else if byte == 34 {
                bytes[index] = 32
                inString = true
            }
            index += 1
        }
        return bytes
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
