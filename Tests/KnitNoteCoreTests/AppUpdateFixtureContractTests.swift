import Foundation
import Testing

@Suite struct AppUpdateFixtureContractTests {
    @Test func fixtureResolveOwnerIsDebugOnlyStrictAndDeterministic() throws {
        let source = try updateFixtureSource("KnitNote/App/AppUpdateFixture.swift")

        #expect(try fixtureResolveFailures(in: source).isEmpty)
    }

    @Test(arguments: FixtureMutation.all)
    func scopedFixtureContractsRejectOwnerMutationsDespiteCommentDecoys(
        _ mutation: FixtureMutation
    ) throws {
        let source = try updateFixtureSource(mutation.relativePath)
        let ownerBlock = try updateFixtureOwnerBlock(mutation.owner, in: source)
        let mutatedOwner = try #require(ownerBlock.replacingFirstFixtureOccurrence(
            of: mutation.token,
            with: mutation.replacement
        ))
        let mutatedSource = source.replacingOccurrences(of: ownerBlock, with: mutatedOwner)
            + "\n/* out-of-owner decoy:\n\(mutation.decoy)\n*/\n"

        let failures = switch mutation.owner {
        case .fixtureResolve, .fixtureArgumentValue:
            try fixtureResolveFailures(in: mutatedSource)
        case .liveFactoryMake:
            try liveFactoryFailures(in: mutatedSource)
        }
        #expect(failures == [mutation.expectedFailure])
    }

    @Test func productionAppKeepsFixtureRoutingAndSharesUpdatesOutsideTheSessionBoundary() throws {
        let source = try updateFixtureSource("KnitNote/App/KnitNoteApp.swift")
        let appInit = try updateFixtureFunction(signature: "    init()", in: source)
        let body = try updateFixtureFunction(signature: "    var body: some Scene", in: source)
        let screenshotResolution = try #require(appInit.range(of: "StoreScreenshotMode.resolve()"))
        let fixtureResolution = try #require(appInit.range(of: "AppUpdateFixture.resolve("))

        #expect(screenshotResolution.lowerBound < fixtureResolution.lowerBound)
        #expect(appInit.contains("preconditionFailure(\"App update fixture is invalid or overlaps screenshot mode\")"))
        #expect(appInit.contains("if screenshotMode == nil"))
        #expect(appInit.contains("AppUpdateReminderLiveFactory.make(fixture: appUpdateFixture)"))
        #expect(appInit.contains("if screenshotMode == nil {\n            appUpdateReminderCoordinator = AppUpdateReminderLiveFactory.make(fixture: appUpdateFixture)\n        } else {\n            appUpdateReminderCoordinator = AppUpdateReminderCoordinator(\n                enabled: false,"))
        #expect(body.contains("AppSessionRootView(owner: sessionOwner)"))
        #expect(body.contains("RootView(storedLanguage: $storedLanguage)"))
        let unavailable = try #require(body.range(of: "} unavailable: {"))
        let sharedUpdate = try #require(body.range(of: ".environmentObject(appUpdateReminderCoordinator)"))
        #expect(unavailable.lowerBound < sharedUpdate.lowerBound)
        #expect(body.contains(".environmentObject(entitlementCoordinator)\n                .environmentObject(appUpdateReminderCoordinator)"))
        #expect(!appInit.contains("ProcessInfo.processInfo.environment"))
    }

    @Test func liveFactoryOwnerUsesStorefrontImmediatelyBeforeLookupAndFixtureNeverCallsIt() throws {
        let source = try updateFixtureSource("KnitNote/App/AppUpdateReminderLiveFactory.swift")

        #expect(source.hasPrefix("import Foundation\nimport StoreKit\n"))
        #expect(try liveFactoryFailures(in: source).isEmpty)
    }
}

struct FixtureMutation: Sendable, CustomTestStringConvertible {
    let name: String
    let relativePath: String
    let owner: UpdateFixtureOwner
    let token: String
    let replacement: String
    let expectedFailure: UpdateFixtureRequirement
    let decoy: String

    init(
        name: String,
        relativePath: String,
        owner: UpdateFixtureOwner,
        token: String,
        replacement: String,
        expectedFailure: UpdateFixtureRequirement,
        decoy: String? = nil
    ) {
        self.name = name
        self.relativePath = relativePath
        self.owner = owner
        self.token = token
        self.replacement = replacement
        self.expectedFailure = expectedFailure
        self.decoy = decoy ?? token
    }

    var testDescription: String { name }

    static let all: [Self] = [
        Self(
            name: "DEBUG guard",
            relativePath: "KnitNote/App/AppUpdateFixture.swift",
            owner: .fixtureResolve,
            token: "#if DEBUG",
            replacement: "#if !DEBUG",
            expectedFailure: .debugGuard
        ),
        Self(
            name: "Release invalid branch",
            relativePath: "KnitNote/App/AppUpdateFixture.swift",
            owner: .fixtureResolve,
            token: "#else\n        return .invalid\n#endif",
            replacement: "#else\n        return .notRequested\n#endif",
            expectedFailure: .releaseInvalid
        ),
        Self(
            name: "exact opt-in flag and value",
            relativePath: "KnitNote/App/AppUpdateFixture.swift",
            owner: .fixtureResolve,
            token: "argumentValue(after: \"-appUpdateFixture\", in: arguments) == \"YES\"",
            replacement: "argumentValue(after: \"-appUpdateFixture\", in: arguments) == \"NO\"",
            expectedFailure: .exactOptIn
        ),
        Self(
            name: "screenshot overlap blocker",
            relativePath: "KnitNote/App/AppUpdateFixture.swift",
            owner: .fixtureResolve,
            token: "!arguments.contains(\"-storeScreenshotMode\")",
            replacement: "true",
            expectedFailure: .screenshotBlocker
        ),
        Self(
            name: "canonical fixture Store URL sentinel",
            relativePath: "KnitNote/App/AppUpdateFixture.swift",
            owner: .fixtureResolve,
            token: "AppStoreUpdateLiveNetworkContract\n                .debugFixtureStoreURL()",
            replacement: "URL(string: \"https://example.com\")",
            expectedFailure: .deterministicStoreURL
        ),
        Self(
            name: "fixture bypass before live fetch",
            relativePath: "KnitNote/App/AppUpdateReminderLiveFactory.swift",
            owner: .liveFactoryMake,
            token: "                if let fixture {\n                    return fixture.availableUpdate\n                }\n                return await lookup.fetch(countryCode: countryCode, platform: platform)",
            replacement: "                let liveUpdate = await lookup.fetch(countryCode: countryCode, platform: platform)\n                if let fixture {\n                    return fixture.availableUpdate\n                }\n                return liveUpdate",
            expectedFailure: .fixtureBypassesLiveFetch
        ),
        Self(
            name: "argumentValue environment override",
            relativePath: "KnitNote/App/AppUpdateFixture.swift",
            owner: .fixtureArgumentValue,
            token: "        guard let index = arguments.firstIndex(of: flag),",
            replacement: "        if let override = ProcessInfo.processInfo.environment[flag] {\n            return override\n        }\n        guard let index = arguments.firstIndex(of: flag),",
            expectedFailure: .noEnvironmentOverride,
            decoy: "ProcessInfo.processInfo.environment[flag]"
        ),
    ]
}

enum UpdateFixtureOwner: Sendable {
    case fixtureResolve
    case fixtureArgumentValue
    case liveFactoryMake
}

enum UpdateFixtureRequirement: String, Hashable, Sendable {
    case debugGuard
    case releaseInvalid
    case exactOptIn
    case strictVersion
    case deterministicStoreURL
    case screenshotBlocker
    case uniqueFlags
    case noEnvironmentOverride
    case storefrontResolution
    case fixtureBypassesLiveFetch
}

private func fixtureResolveFailures(in source: String) throws -> Set<UpdateFixtureRequirement> {
    let resolveOwner = try updateFixtureOwnerBlock(.fixtureResolve, in: source)
    let argumentValueOwner = try updateFixtureOwnerBlock(.fixtureArgumentValue, in: source)
    var failures = Set<UpdateFixtureRequirement>()
    let requirements: [(String, UpdateFixtureRequirement)] = [
        ("#if DEBUG", .debugGuard),
        ("#else\n        return .invalid\n#endif", .releaseInvalid),
        ("argumentValue(after: \"-appUpdateFixture\", in: arguments) == \"YES\"", .exactOptIn),
        ("after: \"-appUpdateFixtureVersion\"", .strictVersion),
        ("AppVersion(rawVersion)", .strictVersion),
        (
            "AppStoreUpdateLiveNetworkContract\n                .debugFixtureStoreURL()",
            .deterministicStoreURL
        ),
        ("!arguments.contains(\"-storeScreenshotMode\")", .screenshotBlocker),
        ("arguments.occurrences(of: \"-appUpdateFixture\") == 1", .uniqueFlags),
        ("arguments.occurrences(of: \"-appUpdateFixtureVersion\") == 1", .uniqueFlags),
    ]
    for (token, requirement) in requirements where !resolveOwner.contains(token) {
        failures.insert(requirement)
    }
    let argumentOwners = [resolveOwner, argumentValueOwner]
    if argumentOwners.contains(where: {
        $0.contains("environment[") || $0.contains("environmentVariable")
    }) {
        failures.insert(.noEnvironmentOverride)
    }
    return failures
}

private func liveFactoryFailures(in source: String) throws -> Set<UpdateFixtureRequirement> {
    let ownerBlock = try updateFixtureOwnerBlock(.liveFactoryMake, in: source)
    var failures = Set<UpdateFixtureRequirement>()
    let storefrontTokens = [
        "let storefrontCode = await Storefront.current?.countryCode",
        "Locale(identifier: \"en_\\($0)\").region?.identifier",
        "AppStoreUpdateLookup.normalizedCountryCode(alpha2)",
        "AppStoreUpdateLookup.normalizedCountryCode(Locale.current.region?.identifier)",
        "?? \"tw\"",
    ]
    if !storefrontTokens.allSatisfy(ownerBlock.contains) {
        failures.insert(.storefrontResolution)
    }
    let fixtureBypass = "                if let fixture {\n                    return fixture.availableUpdate\n                }\n                return await lookup.fetch(countryCode: countryCode, platform: platform)"
    if !ownerBlock.contains(fixtureBypass) {
        failures.insert(.fixtureBypassesLiveFetch)
    }
    return failures
}

private func updateFixtureOwnerBlock(
    _ owner: UpdateFixtureOwner,
    in source: String
) throws -> String {
    switch owner {
    case .fixtureResolve:
        let startMarker = "    static func resolve("
        let endMarker = "\n    private static func argumentValue("
        let starts = source.components(separatedBy: startMarker)
        let ends = source.components(separatedBy: endMarker)
        guard starts.count == 2, ends.count == 2,
              let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker)?.lowerBound,
              start < end else {
            throw UpdateFixtureContractError.missingUniqueOwner
        }
        return String(source[start..<end])
    case .fixtureArgumentValue:
        return try updateFixtureFunction(
            signature: "    private static func argumentValue(",
            in: source
        )
    case .liveFactoryMake:
        return try updateFixtureFunction(signature: "    static func make(", in: source)
    }
}

private func updateFixtureFunction(signature: String, in source: String) throws -> String {
    let signatures = source.components(separatedBy: signature)
    guard signatures.count == 2,
          let start = source.range(of: signature)?.lowerBound,
          let openingBrace = source[start...].firstIndex(of: "{") else {
        throw UpdateFixtureContractError.missingUniqueOwner
    }
    var depth = 0
    var cursor = openingBrace
    while cursor < source.endIndex {
        switch source[cursor] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[start...cursor])
            }
        default:
            break
        }
        cursor = source.index(after: cursor)
    }
    throw UpdateFixtureContractError.missingUniqueOwner
}

private enum UpdateFixtureContractError: Error {
    case missingUniqueOwner
}

private extension String {
    func replacingFirstFixtureOccurrence(of needle: String, with replacement: String) -> String? {
        guard let range = range(of: needle) else { return nil }
        var copy = self
        copy.replaceSubrange(range, with: replacement)
        return copy
    }
}

private func updateFixtureSource(_ relativePath: String) throws -> String {
    try String(contentsOf: updateFixtureRepositoryRoot.appending(path: relativePath), encoding: .utf8)
}

private let updateFixtureRepositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
