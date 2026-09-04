import Foundation
import Testing

private let canonicalProjectArchiveSchemaSource = """
extension ProjectArchive {
    public static let currentVersion = 14
}

"""

struct SignedCloudEntitlementMutation: Sendable, CustomTestStringConvertible {
    enum Product: String, Sendable { case iOS, macOS, watch, share }
    enum Kind: String, Sendable {
        case missingContainer, wrongContainer, extraContainer
        case missingServices, wrongServices, extraServices
        case missingEnvironment, wrongEnvironment, extraEnvironment
        case missingAPS, wrongAPS, extraAPS
        case conflictingIdentifierAlias
        case extraIOSAPS, extraMacAPS
    }

    let product: Product
    let kind: Kind

    var testDescription: String { "\(product.rawValue)-\(kind.rawValue)" }
}

struct ProductIdentifierMutation: Sendable, CustomTestStringConvertible {
    enum Product: String, CaseIterable, Sendable { case iOS, macOS, watch, share }
    enum Location: String, CaseIterable, Sendable { case profile, signed }
    enum Kind: String, CaseIterable, Sendable {
        case missingCanonical
        case alternateOnly
        case extraCorrectAlias
        case extraConflictingAlias
    }

    let product: Product
    let location: Location
    let kind: Kind

    static let all: [Self] = Product.allCases.flatMap { product in
        Location.allCases.flatMap { location in
            Kind.allCases.map { Self(product: product, location: location, kind: $0) }
        }
    }

    var testDescription: String { "\(product.rawValue)-\(location.rawValue)-\(kind.rawValue)" }
}

struct BaseConfigurationMutation: Sendable, CustomTestStringConvertible {
    enum KeySyntax: String, CaseIterable, Sendable {
        case unquoted
        case quoted
        case escapedQuoted

        var assignmentKey: String {
            switch self {
            case .unquoted: "baseConfigurationReference"
            case .quoted: #""baseConfigurationReference""#
            case .escapedQuoted: #""baseConfigurationReferenc\U0065""#
            }
        }
    }

    let owner: String
    let configuration: String
    let keySyntax: KeySyntax

    static let all: [Self] = [
        #"PBXProject "KnitNote""#,
        #"PBXNativeTarget "KnitNote""#,
        #"PBXNativeTarget "KnitNoteWatch""#,
        #"PBXNativeTarget "KnitNoteShare""#,
    ].flatMap { owner in
        ["Debug", "Release"].flatMap { configuration in
            KeySyntax.allCases.map {
                Self(owner: owner, configuration: configuration, keySyntax: $0)
            }
        }
    }

    var testDescription: String { "\(owner)-\(configuration)-\(keySyntax.rawValue)" }
}

struct PBXGraphMutation: Sendable, CustomTestStringConvertible {
    enum Kind: String, Sendable {
        case rootClass
        case targetClass
        case targetProductName
        case duplicateTarget
        case configurationListClass
        case configurationClass
        case danglingConfigurationList
        case danglingConfiguration
        case danglingTarget
    }

    let owner: String
    let configuration: String?
    let kind: Kind

    static let all: [Self] = {
        let owners = [
            #"PBXProject "KnitNote""#,
            #"PBXNativeTarget "KnitNote""#,
            #"PBXNativeTarget "KnitNoteWatch""#,
            #"PBXNativeTarget "KnitNoteShare""#,
        ]
        var result = [Self(owner: owners[0], configuration: nil, kind: .rootClass)]
        for owner in owners.dropFirst() {
            result.append(Self(owner: owner, configuration: nil, kind: .targetClass))
            result.append(Self(owner: owner, configuration: nil, kind: .targetProductName))
            result.append(Self(owner: owner, configuration: nil, kind: .duplicateTarget))
        }
        for owner in owners {
            result.append(Self(owner: owner, configuration: nil, kind: .configurationListClass))
            result.append(Self(owner: owner, configuration: nil, kind: .danglingConfigurationList))
            for configuration in ["Debug", "Release"] {
                result.append(Self(owner: owner, configuration: configuration, kind: .configurationClass))
                result.append(Self(owner: owner, configuration: configuration, kind: .danglingConfiguration))
            }
        }
        result.append(Self(owner: owners[0], configuration: nil, kind: .danglingTarget))
        return result
    }()

    var testDescription: String {
        "\(kind.rawValue)-\(owner)-\(configuration ?? "all")"
    }
}

struct PBXDuplicateSettingMutation: Sendable, CustomTestStringConvertible {
    enum Syntax: String, CaseIterable, Sendable {
        case unquoted, quoted, escaped

        func spelling(_ key: String) -> String {
            switch self {
            case .unquoted: return key
            case .quoted: return "\"\(key)\""
            case .escaped:
                let index = key.index(before: key.endIndex)
                let scalar = key[index].unicodeScalars.first!.value
                return "\"\(key[..<index])\\U\(String(format: "%04X", scalar))\""
            }
        }
    }

    enum Order: String, CaseIterable, Sendable { case evilFirst, evilLast }

    let product: String
    let owner: String
    let configuration: String
    let key: String
    let canonicalValue: String
    let evilValue: String
    let syntax: Syntax
    let order: Order

    static let all: [Self] = {
        let products = [
            ("iOS", #"PBXNativeTarget "KnitNote""#, "CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]", "KnitNote/KnitNote-iOS.entitlements"),
            ("macOS", #"PBXNativeTarget "KnitNote""#, "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]", "KnitNote/KnitNote-macOS.entitlements"),
            ("Watch", #"PBXNativeTarget "KnitNoteWatch""#, "INFOPLIST_FILE", "KnitNoteWatch/Info.plist"),
            ("Share", #"PBXNativeTarget "KnitNoteShare""#, "CODE_SIGN_ENTITLEMENTS", "KnitNoteShare/KnitNoteShare.entitlements"),
            ("iOS-Info", #"PBXNativeTarget "KnitNote""#, "INFOPLIST_FILE", "KnitNote/Info.plist"),
            ("macOS-Info", #"PBXNativeTarget "KnitNote""#, "INFOPLIST_FILE", "KnitNote/Info.plist"),
            ("Watch-Info", #"PBXNativeTarget "KnitNoteWatch""#, "INFOPLIST_FILE", "KnitNoteWatch/Info.plist"),
            ("Share-Info", #"PBXNativeTarget "KnitNoteShare""#, "INFOPLIST_FILE", "KnitNoteShare/Info.plist"),
        ]
        return products.flatMap { product, owner, key, canonical in
            ["Debug", "Release"].flatMap { configuration in
                let syntaxes = key.contains("[")
                    ? Syntax.allCases.filter { $0 != .unquoted }
                    : Syntax.allCases
                return syntaxes.flatMap { syntax in
                    Order.allCases.map { order in
                        Self(
                            product: product,
                            owner: owner,
                            configuration: configuration,
                            key: key,
                            canonicalValue: canonical,
                            evilValue: "Evil/Injected.plist",
                            syntax: syntax,
                            order: order
                        )
                    }
                }
            }
        }
    }()

    var testDescription: String {
        "\(product)-\(configuration)-\(key)-\(syntax.rawValue)-\(order.rawValue)"
    }
}

@Suite(.serialized) struct ReleaseAuditLocalizationTests {
    @Test(arguments: PBXGraphMutation.all)
    func staticAuditRejectsUntypedAmbiguousOrDanglingPBXGraph(
        mutation: PBXGraphMutation
    ) throws {
        let source = try String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("KnitNote.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let mutated = try mutatePBXGraph(source, mutation: mutation)
        let result = try runStaticAudit(projectFileSource: mutated)

        #expect(result.status != 0)
        let expected: String = switch mutation.kind {
        case .rootClass: "generated project object graph is invalid"
        case .targetClass: "target graph is invalid"
        case .targetProductName: "target product mapping is invalid"
        case .duplicateTarget: "target is ambiguous"
        case .configurationListClass, .configurationClass,
             .danglingConfigurationList, .danglingConfiguration:
            "configuration is missing"
        case .danglingTarget: "generated project target graph is invalid"
        }
        #expect(result.output.contains(expected), Comment(rawValue: result.output))
    }

    @Test(arguments: PBXDuplicateSettingMutation.all)
    func staticAuditRejectsLexicallyDuplicateRelevantBuildSettings(
        mutation: PBXDuplicateSettingMutation
    ) throws {
        let source = try String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("KnitNote.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let mutated = try #require(generatedProjectByDuplicatingBuildSetting(
            source,
            mutation: mutation
        ))
        let result = try runStaticAudit(projectFileSource: mutated)

        #expect(result.status != 0)
        #expect(result.output.contains("duplicate"), Comment(rawValue: result.output))
    }

    @Test(arguments: BaseConfigurationMutation.all)
    func staticAuditRejectsLexicallyDuplicateBaseConfigurationReferences(
        mutation: BaseConfigurationMutation
    ) throws {
        let source = try String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("KnitNote.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let original = try #require(generatedBuildConfiguration(
            in: source,
            owner: mutation.owner,
            configuration: mutation.configuration
        ))
        let insertion = try #require(original.range(of: "isa = XCBuildConfiguration;"))
        var changed = original
        let first = "\n\t\t\tbaseConfigurationReference = AAAAAAAAAAAAAAAAAAAAAAAA /* First.xcconfig */;"
        let second = "\n\t\t\t\"baseConfigurationReferenc\\U0065\" = BBBBBBBBBBBBBBBBBBBBBBBB /* Second.xcconfig */;"
        changed.insert(contentsOf: first + second, at: insertion.upperBound)
        let result = try runStaticAudit(
            projectFileSource: source.replacingOccurrences(of: original, with: changed)
        )

        #expect(result.status != 0)
        #expect(result.output.contains("duplicate"), Comment(rawValue: result.output))
    }

    @Test func staticAuditScopesDuplicateDetectionAndIgnoresCommentStringAndUnreferencedDecoys() throws {
        let source = try String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("KnitNote.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let configuration = try #require(generatedBuildConfiguration(
            in: source,
            owner: #"PBXProject "KnitNote""#,
            configuration: "Debug"
        ))
        let insertion = try #require(configuration.range(of: "buildSettings = {\n"))
        var changedConfiguration = configuration
        changedConfiguration.insert(
            contentsOf: "\t\t\t\t/* CODE_SIGN_ENTITLEMENTS = Evil/Comment.entitlements; */\n"
                + "\t\t\t\tPBX_DUPLICATE_DECOY = \"INFOPLIST_FILE = Evil/String.plist;\";\n",
            at: insertion.upperBound
        )
        var mutated = source.replacingOccurrences(of: configuration, with: changedConfiguration)
        let sectionEnd = try #require(mutated.range(of: "/* End XCBuildConfiguration section */"))
        mutated.insert(contentsOf: """

		D00D00000000000000000001 /* Unreferenced */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				INFOPLIST_FILE = Evil/First.plist;
				"INFOPLIST_FIL\\U0045" = Evil/Second.plist;
			};
			name = Decoy;
		};

""", at: sectionEnd.lowerBound)

        let result = try runStaticAudit(projectFileSource: mutated)
        #expect(result.status == 0, Comment(rawValue: result.output))
    }

    @Test(arguments: ProductIdentifierMutation.all)
    func archiveAuditRejectsEachProfileAndSignedIdentifierAliasAmbiguity(
        mutation: ProductIdentifierMutation
    ) throws {
        let fixture = try makeArchiveFixture(identifierMutation: mutation)
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        let expected = mutation.location == .profile
            ? "provisioning profile is expired or is not App Store distribution"
            : "signed entitlements do not match"
        #expect(result.output.contains(expected), Comment(rawValue: result.output))
    }

    @Test(arguments: [
        SignedCloudEntitlementMutation(product: .iOS, kind: .missingContainer),
        SignedCloudEntitlementMutation(product: .iOS, kind: .wrongContainer),
        SignedCloudEntitlementMutation(product: .iOS, kind: .extraContainer),
        SignedCloudEntitlementMutation(product: .iOS, kind: .missingServices),
        SignedCloudEntitlementMutation(product: .iOS, kind: .wrongServices),
        SignedCloudEntitlementMutation(product: .iOS, kind: .extraServices),
        SignedCloudEntitlementMutation(product: .iOS, kind: .missingEnvironment),
        SignedCloudEntitlementMutation(product: .iOS, kind: .wrongEnvironment),
        SignedCloudEntitlementMutation(product: .iOS, kind: .extraEnvironment),
        SignedCloudEntitlementMutation(product: .iOS, kind: .missingAPS),
        SignedCloudEntitlementMutation(product: .iOS, kind: .wrongAPS),
        SignedCloudEntitlementMutation(product: .iOS, kind: .extraAPS),
        SignedCloudEntitlementMutation(product: .iOS, kind: .conflictingIdentifierAlias),
        SignedCloudEntitlementMutation(product: .macOS, kind: .missingContainer),
        SignedCloudEntitlementMutation(product: .macOS, kind: .wrongContainer),
        SignedCloudEntitlementMutation(product: .macOS, kind: .extraContainer),
        SignedCloudEntitlementMutation(product: .macOS, kind: .missingServices),
        SignedCloudEntitlementMutation(product: .macOS, kind: .wrongServices),
        SignedCloudEntitlementMutation(product: .macOS, kind: .extraServices),
        SignedCloudEntitlementMutation(product: .macOS, kind: .missingEnvironment),
        SignedCloudEntitlementMutation(product: .macOS, kind: .wrongEnvironment),
        SignedCloudEntitlementMutation(product: .macOS, kind: .extraEnvironment),
        SignedCloudEntitlementMutation(product: .macOS, kind: .missingAPS),
        SignedCloudEntitlementMutation(product: .macOS, kind: .wrongAPS),
        SignedCloudEntitlementMutation(product: .macOS, kind: .extraAPS),
        SignedCloudEntitlementMutation(product: .macOS, kind: .conflictingIdentifierAlias),
        SignedCloudEntitlementMutation(product: .watch, kind: .extraContainer),
        SignedCloudEntitlementMutation(product: .watch, kind: .extraServices),
        SignedCloudEntitlementMutation(product: .watch, kind: .extraEnvironment),
        SignedCloudEntitlementMutation(product: .watch, kind: .extraIOSAPS),
        SignedCloudEntitlementMutation(product: .watch, kind: .extraMacAPS),
        SignedCloudEntitlementMutation(product: .watch, kind: .conflictingIdentifierAlias),
        SignedCloudEntitlementMutation(product: .share, kind: .extraContainer),
        SignedCloudEntitlementMutation(product: .share, kind: .extraServices),
        SignedCloudEntitlementMutation(product: .share, kind: .extraEnvironment),
        SignedCloudEntitlementMutation(product: .share, kind: .extraIOSAPS),
        SignedCloudEntitlementMutation(product: .share, kind: .extraMacAPS),
        SignedCloudEntitlementMutation(product: .share, kind: .conflictingIdentifierAlias),
    ])
    func archiveAuditRejectsMissingWrongOrExtraCloudEntitlements(
        mutation: SignedCloudEntitlementMutation
    ) throws {
        let fixture = try makeArchiveFixture(signedCloudEntitlementMutation: mutation)
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("signed entitlements do not match"))
    }

    @Test(arguments: [
        ("KnitNote/KnitNote-iOS.entitlements", "KnitNote/KnitNote-iOS-CloudKit-APS.entitlements", "iOS/macOS"),
        ("KnitNote/KnitNote-macOS.entitlements", "KnitNote/KnitNote-macOS-CloudKit-APS.entitlements", "iOS/macOS"),
        ("KnitNoteShare/KnitNoteShare.entitlements", "KnitNoteShare/KnitNoteShare-APS.entitlements", "Share"),
    ])
    func staticAuditRejectsAlternateEntitlementBindingEvenWhenItsNameLooksRelevant(
        canonical: String,
        alternate: String,
        product: String
    ) throws {
        let source = try String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("KnitNote.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let mutated = try #require(source.replacingFirstOccurrence(of: canonical, with: alternate))
        let result = try runStaticAudit(projectFileSource: mutated)

        #expect(result.status != 0)
        #expect(result.output.contains("source \(product) CODE_SIGN_ENTITLEMENTS"))
    }

    @Test func staticAuditRejectsAnyWatchEntitlementBinding() throws {
        let source = try String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("KnitNote.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let release = try #require(generatedBuildConfiguration(
            in: source,
            owner: #"PBXNativeTarget "KnitNoteWatch""#,
            configuration: "Release"
        ))
        let mutatedRelease = release.replacingOccurrences(
            of: "buildSettings = {",
            with: "buildSettings = {\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = KnitNoteWatch/CloudKit-APS.entitlements;"
        )
        let mutated = source.replacingOccurrences(of: release, with: mutatedRelease)
        let result = try runStaticAudit(projectFileSource: mutated)

        #expect(result.status != 0)
        #expect(result.output.contains("source Watch CODE_SIGN_ENTITLEMENTS"))
    }

    @Test func staticAuditRejectsInheritedProjectEntitlementBinding() throws {
        let source = try String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("KnitNote.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let release = try #require(generatedBuildConfiguration(
            in: source,
            owner: #"PBXProject "KnitNote""#,
            configuration: "Release"
        ))
        let mutatedRelease = release.replacingOccurrences(
            of: "buildSettings = {",
            with: "buildSettings = {\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = Project/Innocuous.entitlements;"
        )
        let mutated = source.replacingOccurrences(of: release, with: mutatedRelease)
        let result = try runStaticAudit(projectFileSource: mutated)

        #expect(result.status != 0)
        #expect(result.output.contains("project CODE_SIGN_ENTITLEMENTS"))
    }

    @Test(arguments: BaseConfigurationMutation.all)
    func staticAuditRejectsBaseConfigurationReferencesForRelevantConfigurations(
        mutation: BaseConfigurationMutation
    ) throws {
        let source = try String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("KnitNote.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let release = try #require(generatedBuildConfiguration(
            in: source,
            owner: mutation.owner,
            configuration: mutation.configuration
        ))
        let mutatedRelease = release.replacingOccurrences(
            of: "isa = XCBuildConfiguration;",
            with: "isa = XCBuildConfiguration;\n\t\t\t\(mutation.keySyntax.assignmentKey) = DEADBEEFDEADBEEFDEADBEEF /* Evil.xcconfig */;"
        )
        let result = try runStaticAudit(
            projectFileSource: source.replacingOccurrences(of: release, with: mutatedRelease)
        )

        #expect(result.status != 0)
        #expect(result.output.contains("baseConfigurationReference"))
    }

    @Test func staticAuditRejectsAlternateMainInfoPlistBinding() throws {
        let source = try String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("KnitNote.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let mutated = try #require(source.replacingFirstOccurrence(
            of: "INFOPLIST_FILE = KnitNote/Info.plist;",
            with: "INFOPLIST_FILE = KnitNote/CloudKitRemoteNotificationInfo.plist;"
        ))
        let result = try runStaticAudit(projectFileSource: mutated)

        #expect(result.status != 0)
        #expect(result.output.contains("source iOS/macOS INFOPLIST_FILE"))
    }

    @Test func staticAuditRejectsMainInfoWithoutRemoteNotificationEvenWhenProjectSpecContainsIt() throws {
        let fixture = try sourceInfoPlistFixture(mainModes: nil)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runReleaseAudit(environment: ["KNITNOTE_MAIN_INFO_PLIST": fixture.main.path])

        #expect(result.status != 0)
        #expect(result.output.contains("source main UIBackgroundModes"))
    }

    @Test func staticAuditRejectsRemoteNotificationMovedToWatchInfo() throws {
        let fixture = try sourceInfoPlistFixture(mainModes: nil, watchModes: ["remote-notification"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runReleaseAudit(environment: [
            "KNITNOTE_MAIN_INFO_PLIST": fixture.main.path,
            "KNITNOTE_WATCH_INFO_PLIST": fixture.watch.path,
        ])

        #expect(result.status != 0)
        #expect(result.output.contains("source main UIBackgroundModes"))
    }

    @Test func staticAuditRejectsUnusedInfoDecoyWithRemoteNotification() throws {
        let fixture = try sourceInfoPlistFixture(mainModes: nil, decoyModes: ["remote-notification"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runReleaseAudit(environment: ["KNITNOTE_MAIN_INFO_PLIST": fixture.main.path])

        #expect(result.status != 0)
        #expect(result.output.contains("source main UIBackgroundModes"))
    }

    @Test func staticAuditRejectsProjectSpecWhoseOnlyRemoteNotificationIsADecoy() throws {
        let fixture = try projectSpecFixture { specification in
            var targets = try #require(specification["targets"] as? [String: Any])
            var main = try #require(targets["KnitNote"] as? [String: Any])
            var info = try #require(main["info"] as? [String: Any])
            var properties = try #require(info["properties"] as? [String: Any])
            properties.removeValue(forKey: "UIBackgroundModes")
            info["properties"] = properties
            main["info"] = info
            targets["KnitNote"] = main
            specification["targets"] = targets
            specification["UIBackgroundModesDecoy"] = ["remote-notification"]
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runReleaseAudit(environment: ["KNITNOTE_XCODEGEN": fixture.xcodegen.path])

        #expect(result.status != 0)
        #expect(result.output.contains("source main target UIBackgroundModes"))
    }

    @Test func staticAuditRejectsAnyExtraMainBackgroundMode() throws {
        let fixture = try sourceInfoPlistFixture(mainModes: ["remote-notification", "fetch"])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runReleaseAudit(environment: ["KNITNOTE_MAIN_INFO_PLIST": fixture.main.path])

        #expect(result.status != 0)
        #expect(result.output.contains("source main UIBackgroundModes"))
    }

    @Test func staticAuditAcceptsCanonicalProjectArchiveSchemaSource() throws {
        let result = try runStaticAudit(
            projectArchiveSchemaSource: canonicalProjectArchiveSchemaSource
        )

        #expect(result.status == 0)
        #expect(result.output.contains("TEST FIXTURE STATIC AUDIT: PASS"))
    }

    @Test(arguments: [
        canonicalProjectArchiveSchemaSource.replacingOccurrences(of: "= 14", with: "= 13"),
        canonicalProjectArchiveSchemaSource.replacingOccurrences(of: "= 14", with: "= 15"),
        canonicalProjectArchiveSchemaSource
            + "extension ProjectArchive { public static let decoy = 13 }\n",
        "// public static let currentVersion = 13\n" + canonicalProjectArchiveSchemaSource,
        "let decoy = \"public static let currentVersion = 13\"\n"
            + canonicalProjectArchiveSchemaSource,
        "enum Decoy {\n    extension ProjectArchive {\n"
            + "        public static let currentVersion = 13\n    }\n}\n",
        canonicalProjectArchiveSchemaSource + canonicalProjectArchiveSchemaSource,
    ])
    func staticAuditRejectsNoncanonicalProjectArchiveSchemaSource(sourceText: String) throws {
        let result = try runStaticAudit(projectArchiveSchemaSource: sourceText)

        #expect(result.status != 0)
        #expect(result.output.contains("project archive schema source is not canonical schema 14"))
    }

    @Test func staticAuditRejectsNestedFourSpaceSchemaDecoyBesideRealSchemaTwelve() throws {
        let result = try runStaticAudit(projectArchiveSchemaSource: """
            public struct ProjectArchive:
                    Codable {
                    public static let currentVersion = 12
            }

            public enum SchemaDecoy {
                public static let currentVersion = 14
            }
            """)

        #expect(result.status != 0)
        #expect(result.output.contains("project archive schema source is not canonical schema 14"))
    }

    @Test func archiveAuditRejectsOneMissingJapaneseWatchLocalizationDirectory() throws {
        let fixture = try makeArchiveFixture(
            omittingDirectory: (target: "Watch", locale: "ja")
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("Watch bundle is missing ja.lproj"))
    }

    @Test func archiveAuditRejectsExtraSpanishWatchLocalizationDirectory() throws {
        let fixture = try makeArchiveFixture(
            extraDirectory: (target: "Watch", locale: "es")
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("Watch bundle localization directories do not match"))
    }

    @Test func archiveAuditRejectsShareBundleWhoseDeclaredLocalizationsAreIncomplete() throws {
        let fixture = try makeArchiveFixture(
            localizationOverrides: ["Share": releaseLocales.filter { $0 != "fr" }]
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("Share CFBundleLocalizations do not match"))
    }

    @Test func archiveAuditRejectsPreviousVersionAcrossShippingProducts() throws {
        let fixture = try makeArchiveFixture(version: "1.5.1", build: "11")
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("iOS product version is 1.5.1, expected 1.7.0"))
    }

    @Test func archiveAuditRejectsPreviousBuildAcrossShippingProducts() throws {
        let fixture = try makeArchiveFixture(version: "1.7.0", build: "12")
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("iOS product build is 12, expected 13"))
    }

    @Test func staticAuditRejectsGeneratedProjectMissingOneReleaseRegion() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("knitnote-project-regions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let project = temporaryRoot.appendingPathComponent("project.pbxproj")
        try """
        developmentRegion = en;
        knownRegions = (
            Base,
            de,
            en,
            fr,
            "zh-Hans",
            "zh-Hant",
        );
        """.write(to: project, atomically: true, encoding: .utf8)

        let result = try runReleaseAudit(
            environment: ["KNITNOTE_PROJECT_FILE": project.path]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("project knownRegions do not match"))
    }

    @Test func staticAuditRejectsAnyAdditionalTopLevelSharedBuildableProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knitnote-project-inventory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, schemeNames) in [
            ("KnitNote.xcodeproj", ["KnitNote", "KnitNoteWatch", "KnitNoteShare"]),
            ("Archive.xcodeproj", ["KnitNote"]),
        ] {
            let schemes = root.appendingPathComponent(name).appendingPathComponent("xcshareddata/xcschemes")
            try FileManager.default.createDirectory(
                at: schemes,
                withIntermediateDirectories: true
            )
            for schemeName in schemeNames {
                try "<Scheme/>".write(
                    to: schemes.appendingPathComponent("\(schemeName).xcscheme"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        let result = try runReleaseAudit(environment: ["KNITNOTE_PROJECT_SCAN_ROOT": root.path])
        #expect(result.status != 0)
        #expect(result.output.contains("top-level Xcode project and shared scheme inventory is not canonical"))
    }

    @Test func staticAuditRejectsIncompleteInfoPlistCatalog() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("knitnote-info-plist-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let catalog = temporaryRoot.appendingPathComponent("InfoPlist.xcstrings")
        let incompleteCatalog: [String: Any] = [
            "sourceLanguage": "en",
            "strings": [
                "CFBundleDisplayName": [
                    "localizations": Dictionary(
                        uniqueKeysWithValues: releaseLocales
                            .filter { $0 != "ja" }
                            .map { locale in
                                (
                                    locale,
                                    ["stringUnit": ["state": "translated", "value": "KnitNote"]]
                                )
                            }
                    ),
                ],
            ],
            "version": "1.0",
        ]
        let data = try JSONSerialization.data(withJSONObject: incompleteCatalog)
        try data.write(to: catalog)

        let result = try runReleaseAudit(
            environment: ["KNITNOTE_INFO_PLIST_CATALOG": catalog.path]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("InfoPlist.xcstrings has an incomplete thirteen-locale variation"))
    }

    @Test func staticAuditRejectsInfoPlistCatalogWithExtraSpanishLocalization() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("knitnote-extra-info-plist-locale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let catalog = temporaryRoot.appendingPathComponent("InfoPlist.xcstrings")
        let localizations = Dictionary(
            uniqueKeysWithValues: (releaseLocales + ["es"]).map { locale in
                (
                    locale,
                    ["stringUnit": ["state": "translated", "value": "KnitNote"]]
                )
            }
        )
        let catalogWithExtraLocale: [String: Any] = [
            "sourceLanguage": "en",
            "strings": [
                "CFBundleDisplayName": ["localizations": localizations],
            ],
            "version": "1.0",
        ]
        let data = try JSONSerialization.data(withJSONObject: catalogWithExtraLocale)
        try data.write(to: catalog)

        let result = try runReleaseAudit(
            environment: ["KNITNOTE_INFO_PLIST_CATALOG": catalog.path]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("InfoPlist.xcstrings localization key domain does not match"))
    }

    @Test func staticAuditRejectsSourceInfoPlistWithoutThirteenDeclaredLocalizations() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("knitnote-source-info-plists-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
        let main = temporaryRoot.appendingPathComponent("Main-Info.plist")
        let watch = temporaryRoot.appendingPathComponent("Watch-Info.plist")
        let share = temporaryRoot.appendingPathComponent("Share-Info.plist")
        try writePlist(["CFBundleLocalizations": releaseLocales], to: main)
        try writePlist(["CFBundleLocalizations": releaseLocales], to: watch)
        try writePlist(
            ["CFBundleLocalizations": releaseLocales.filter { $0 != "fr" }],
            to: share
        )

        let result = try runReleaseAudit(
            environment: [
                "KNITNOTE_MAIN_INFO_PLIST": main.path,
                "KNITNOTE_WATCH_INFO_PLIST": watch.path,
                "KNITNOTE_SHARE_INFO_PLIST": share.path,
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("Share source CFBundleLocalizations do not match"))
    }

    @Test func staticAuditRejectsChangedSourceMacSecurityContract() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knitnote-source-mac-entitlements-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let entitlements = root.appendingPathComponent("KnitNote-macOS.entitlements")
        try writePlist(
            [
                "com.apple.security.app-sandbox": true,
                "com.apple.security.files.user-selected.read-write": false,
                "com.apple.security.network.client": true,
            ],
            to: entitlements
        )

        let result = try runReleaseAudit(
            environment: ["KNITNOTE_MAC_ENTITLEMENTS": entitlements.path]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("source Mac entitlements do not match the production security contract"))
    }

    @Test func archiveAuditAcceptsThirteenMatchingLocalizationsPlusBaseOnEveryShippingBundle() throws {
        let fixture = try makeArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status == 0)
        #expect(result.output.contains("TEST FIXTURE ARCHIVE AUDIT: PASS"))
        #expect(!result.output.split(separator: "\n").contains("RELEASE AUDIT: PASS"))
        let extractedDirectories = try String(contentsOf: fixture.extractionLog, encoding: .utf8)
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
        #expect(extractedDirectories.count == 2)
        #expect(extractedDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func archiveAuditRejectsUnreadableMacPackagePayload() throws {
        let unreadableFileFixture = try makeArchiveFixture()
        defer { try? FileManager.default.removeItem(at: unreadableFileFixture.temporaryRoot) }
        let executable = unreadableFileFixture.macPackageApp
            .appendingPathComponent("Contents/MacOS/KnitNote")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: executable.path
        )

        let unreadableFileResult = try runReleaseAudit(
            archives: unreadableFileFixture.archives,
            environment: ["PATH": unreadableFileFixture.commandPath]
        )
        #expect(unreadableFileResult.status != 0)
        #expect(unreadableFileResult.output.contains(
            "macOS package app contains a file that is not world-readable:"
        ))
        #expect(unreadableFileResult.output.contains("Contents/MacOS/KnitNote"))

        let unsearchableDirectoryFixture = try makeArchiveFixture()
        defer { try? FileManager.default.removeItem(at: unsearchableDirectoryFixture.temporaryRoot) }
        let executableDirectory = unsearchableDirectoryFixture.macPackageApp
            .appendingPathComponent("Contents/MacOS")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableDirectory.path
        )

        let unsearchableDirectoryResult = try runReleaseAudit(
            archives: unsearchableDirectoryFixture.archives,
            environment: ["PATH": unsearchableDirectoryFixture.commandPath]
        )
        #expect(unsearchableDirectoryResult.status != 0)
        #expect(unsearchableDirectoryResult.output.contains(
            "macOS package app contains a directory that is not world-searchable:"
        ))
        #expect(unsearchableDirectoryResult.output.contains("Contents/MacOS"))
    }

    @Test func archiveAuditBindsEveryExportedDistributionArtifactInProvenance() throws {
        let artifacts = [
            "Distribution/iOS/KnitNote.ipa",
            "Distribution/macOS/KnitNote.pkg",
            "Distribution/iOS/DistributionSummary.plist",
            "Distribution/macOS/DistributionSummary.plist",
            "Distribution/iOS/ExportOptions.plist",
            "Distribution/macOS/ExportOptions.plist",
        ]
        for artifact in artifacts {
            let fixture = try makeArchiveFixture(mutateDistributionAfterProvenance: artifact)
            defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

            let result = try runReleaseAudit(
                archives: fixture.archives,
                environment: ["PATH": fixture.commandPath]
            )

            #expect(result.status != 0)
            #expect(result.output.contains("deterministic archive inventory mismatch"))
        }
    }

    @Test func archiveAuditRejectsMissingExportedIPAAndPkg() throws {
        for artifact in ["Distribution/iOS/KnitNote.ipa", "Distribution/macOS/KnitNote.pkg"] {
            let fixture = try makeArchiveFixture(removeDistributionAfterProvenance: artifact)
            defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

            let result = try runReleaseAudit(
                archives: fixture.archives,
                environment: ["PATH": fixture.commandPath]
            )

            #expect(result.status != 0)
            #expect(result.output.contains("deterministic archive inventory mismatch"))
        }
    }

    @Test func archiveAuditRejectsSymlinkedDistributionArtifactAndExtractedAppRoot() throws {
        let artifactFixture = try makeArchiveFixture(
            symlinkDistributionAfterProvenance: "Distribution/iOS/KnitNote.ipa"
        )
        defer { try? FileManager.default.removeItem(at: artifactFixture.temporaryRoot) }
        let artifactResult = try runReleaseAudit(
            archives: artifactFixture.archives,
            environment: ["PATH": artifactFixture.commandPath]
        )
        #expect(artifactResult.status != 0)
        #expect(artifactResult.output.contains("deterministic archive inventory mismatch"))

        let rootFixture = try makeArchiveFixture(symlinkPreparedExportRoot: "iOS")
        defer { try? FileManager.default.removeItem(at: rootFixture.temporaryRoot) }
        let rootResult = try runReleaseAudit(
            archives: rootFixture.archives,
            environment: ["PATH": rootFixture.commandPath]
        )
        #expect(rootResult.status != 0)
        #expect(rootResult.output.contains("exported iOS app root is missing or unsafe"))
    }

    @Test func archiveAuditRejectsIntermediatePayloadSymlinkInsideExtractionRoot() throws {
        let fixture = try makeArchiveFixture(symlinkPreparedIOSPayloadToReal: true)
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("exported iOS app root is missing or unsafe"))
    }

    @Test func provenanceRejectsIntermediateDistributionDirectorySymlink() throws {
        let fixture = try makeArchiveFixture(symlinkDistributionParentAfterProvenance: true)
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("deterministic archive inventory mismatch"))
    }

    @Test func archiveAuditInspectsExtractedProductsAndRejectsExtractionFailuresOrAmbiguity() throws {
        let passing = try makeArchiveFixture(rejectArchiveCodesign: true)
        defer { try? FileManager.default.removeItem(at: passing.temporaryRoot) }
        let passingResult = try runReleaseAudit(
            archives: passing.archives,
            environment: ["PATH": passing.commandPath]
        )
        #expect(passingResult.status == 0, Comment(rawValue: passingResult.output))

        let cases: [(ArchiveFixture, String)] = [
            (try makeArchiveFixture(extractionFailure: "iOS"), "iOS IPA extraction failed"),
            (try makeArchiveFixture(extractionFailure: "macOS"), "macOS pkg expansion failed"),
            (try makeArchiveFixture(omitPreparedExportRoot: "iOS"), "exported iOS app root"),
            (try makeArchiveFixture(omitPreparedExportRoot: "macOS"), "exported macOS app root"),
            (try makeArchiveFixture(ambiguousMacApps: true), "exactly one exported macOS app root"),
        ]
        for (fixture, expected) in cases {
            defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }
            let result = try runReleaseAudit(
                archives: fixture.archives,
                environment: ["PATH": fixture.commandPath]
            )
            #expect(result.status != 0)
            #expect(result.output.contains(expected), Comment(rawValue: result.output))
            if FileManager.default.fileExists(atPath: fixture.extractionLog.path) {
                let paths = try String(contentsOf: fixture.extractionLog, encoding: .utf8)
                    .split(separator: "\n")
                    .map { URL(fileURLWithPath: String($0)) }
                #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            }
        }
    }

    @Test func archiveAuditUsesANonexistentDestinationForPkgutilExpansion() throws {
        let fixture = try makeArchiveFixture(pkgutilRejectsExistingDestination: true)
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("TEST FIXTURE ARCHIVE AUDIT: PASS"))
    }

    @Test func archiveAuditAcceptsMacAppStoreProfileOmittingGetTaskAllow() throws {
        let fixture = try makeArchiveFixture(macProfileGetTaskAllow: nil)
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("TEST FIXTURE ARCHIVE AUDIT: PASS"))
    }

    @Test func archiveAuditRejectsRawPackagingLogsAndUnexpectedDistributionFilesEvenWhenProvenanceBindsThem() throws {
        for file in ["Distribution/iOS/Packaging.log", "Distribution/macOS/Packaging.log", "Distribution/iOS/unexpected.txt"] {
            let fixture = try makeArchiveFixture(extraDistributionBeforeProvenance: file)
            defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

            let result = try runReleaseAudit(
                archives: fixture.archives,
                environment: ["PATH": fixture.commandPath]
            )

            #expect(result.status != 0)
            #expect(result.output.contains("Distribution inventory contains an unexpected or credential-bearing file"), Comment(rawValue: result.output))
        }
    }

    @Test func archiveAuditRequiresTrustedExactTeamMacInstallerPackageSignature() throws {
        let accepted = try makeArchiveFixture(packageSignature: "valid")
        defer { try? FileManager.default.removeItem(at: accepted.temporaryRoot) }
        let acceptedResult = try runReleaseAudit(
            archives: accepted.archives,
            environment: ["PATH": accepted.commandPath]
        )
        #expect(acceptedResult.status == 0, Comment(rawValue: acceptedResult.output))

        let developerIssued = try makeArchiveFixture(packageSignature: "developer-issued")
        defer { try? FileManager.default.removeItem(at: developerIssued.temporaryRoot) }
        let developerIssuedResult = try runReleaseAudit(
            archives: developerIssued.archives,
            environment: ["PATH": developerIssued.commandPath]
        )
        #expect(developerIssuedResult.status == 0, Comment(rawValue: developerIssuedResult.output))

        let indented = try makeArchiveFixture(packageSignature: "indented-valid")
        defer { try? FileManager.default.removeItem(at: indented.temporaryRoot) }
        let indentedResult = try runReleaseAudit(
            archives: indented.archives,
            environment: ["PATH": indented.commandPath]
        )
        #expect(indentedResult.status == 0, Comment(rawValue: indentedResult.output))

        for signature in ["unsigned", "tampered", "wrong-team", "wrong-prefix", "wrong-suffix", "mixed-team", "untrusted", "arbitrary-status", "revoked-status", "error-status", "wrong-chain", "allowed-plus-revoked", "wrong-intermediate-decoy", "repeated-leaf-one"] {
            let fixture = try makeArchiveFixture(packageSignature: signature)
            defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }
            let result = try runReleaseAudit(
                archives: fixture.archives,
                environment: ["PATH": fixture.commandPath]
            )
            #expect(result.status != 0)
            #expect(result.output.contains("macOS pkg is not signed by the required trusted Apple installer distribution"), Comment(rawValue: result.output))
        }
    }

    @Test func provenanceBindsEveryRetainedCandidateEntryExceptCanonicalProvenance() throws {
        let fixture = try makeArchiveFixture(extraDistributionBeforeProvenance: "KnitNote-iOS-Privacy.xcarchive/dSYMs/KnitNote.dSYM")
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }
        #expect(try runManifest("verify", archives: fixture.archives, provenance: fixture.provenance, exportOptions: releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/ExportOptions-AppStore.plist")) == 0)

        let extra = fixture.archives.appendingPathComponent("notes.txt")
        try Data("later extra".utf8).write(to: extra)
        #expect(try runManifest("verify", archives: fixture.archives, provenance: fixture.provenance, exportOptions: releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/ExportOptions-AppStore.plist")) != 0)
        try FileManager.default.removeItem(at: extra)

        let retained = fixture.archives.appendingPathComponent("KnitNote-iOS-Privacy.xcarchive/dSYMs/KnitNote.dSYM")
        try Data("mutated symbol data".utf8).write(to: retained)
        #expect(try runManifest("verify", archives: fixture.archives, provenance: fixture.provenance, exportOptions: releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/ExportOptions-AppStore.plist")) != 0)
    }

    @Test func provenanceRequiresBothRetainedArchivesAndTheirInfoPlists() throws {
        for missing in [
            "KnitNote-iOS-Privacy.xcarchive",
            "KnitNote-macOS-Privacy.xcarchive",
            "KnitNote-iOS-Privacy.xcarchive/Info.plist",
            "KnitNote-macOS-Privacy.xcarchive/Info.plist",
        ] {
            let fixture = try makeArchiveFixture()
            defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }
            try FileManager.default.removeItem(at: fixture.archives.appendingPathComponent(missing))
            #expect(try runManifest("create", archives: fixture.archives, provenance: fixture.provenance, exportOptions: releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/ExportOptions-AppStore.plist")) != 0)
        }
    }

    @Test func archiveAuditRequiresCanonicalCandidateRootProvenance() throws {
        let fixture = try makeArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }
        let alternate = fixture.temporaryRoot.appendingPathComponent("alternate-provenance.json")
        try FileManager.default.copyItem(at: fixture.provenance, to: alternate)
        let result = try runReleaseAudit(
            arguments: ["--archives", fixture.archives.path, "--expected-commit", fixtureCommit, "--provenance", alternate.path],
            environment: ["PATH": fixture.commandPath]
        )
        #expect(result.status != 0)
        #expect(result.output.contains("provenance must be the canonical candidate-root provenance.json"))
    }

    @Test func archiveAuditRejectsTheTestFixtureSentinelBeforePublication() throws {
        let fixture = try makeArchiveFixture(testFixtureSentinelBeforeProvenance: true)
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }
        let result = try runReleaseAudit(archives: fixture.archives, environment: ["PATH": fixture.commandPath])
        #expect(result.status != 0)
        #expect(result.output.contains("candidate contains the test fixture sentinel"))
    }

    @Test func archiveAuditRejectsMacAppStoreProfileGrantingGetTaskAllow() throws {
        let fixture = try makeArchiveFixture(macProfileGetTaskAllow: true)
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("provisioning profile is expired or is not App Store distribution"))
    }

    @Test func productionAuditRejectsExtractionToolOverrides() throws {
        for variable in ["KNITNOTE_DITTO", "KNITNOTE_PKGUTIL"] {
            let result = try runReleaseAudit(
                arguments: ["--static-only"],
                environment: [:],
                productionEnvironment: [variable: "/tmp/fixture-tool"]
            )
            #expect(result.status != 0)
            #expect(result.output.contains("production audit rejects override \(variable)"))
            #expect(!result.output.contains("RELEASE AUDIT: PASS"))
        }
    }

    @Test func provenanceBindsTheCheckedInExportOptionsTemplate() throws {
        let fixture = try makeArchiveFixture()
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }
        let options = fixture.temporaryRoot.appendingPathComponent("ExportOptions-AppStore.plist")
        try FileManager.default.copyItem(
            at: releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/ExportOptions-AppStore.plist"),
            to: options
        )
        let provenance = fixture.temporaryRoot.appendingPathComponent("template-provenance.json")
        #expect(try runManifest("create", archives: fixture.archives, provenance: provenance, exportOptions: options) == 0)
        try Data("mutated options".utf8).write(to: options)
        #expect(try runManifest("verify", archives: fixture.archives, provenance: provenance, exportOptions: options) != 0)
    }

    @Test func archiveAuditRejectsMissingMacInfoPlistTable() throws {
        let fixture = try makeArchiveFixture(
            omittingInfoPlistTable: (target: "macOS", locale: "ko")
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("macOS bundle is missing ko.lproj/InfoPlist.strings"))
    }

    @Test func archiveAuditRejectsWrongAndExtraProductSpecificInfoPlistValues() throws {
        let cases: [(ArchiveFixture, String)] = [
            (
                try makeArchiveFixture(
                    infoPlistValueOverride: (
                        target: "iOS",
                        locale: "nb",
                        key: "KnitNote Backup",
                        value: "Wrong backup description"
                    )
                ),
                "iOS nb InfoPlist effective value differs"
            ),
            (
                try makeArchiveFixture(
                    extraInfoPlistKey: (target: "macOS", locale: "sv")
                ),
                "macOS sv InfoPlist compiled key domain differs"
            ),
        ]
        for (fixture, expected) in cases {
            defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }
            let result = try runReleaseAudit(
                archives: fixture.archives,
                environment: ["PATH": fixture.commandPath]
            )
            #expect(result.status != 0)
            #expect(result.output.contains(expected))
        }
    }

    @Test func archiveAuditRejectsBrokenEnglishInfoPlistSourceFallback() throws {
        let fixture = try makeArchiveFixture(
            englishInfoPlistFallbackOverride: (
                target: "macOS",
                key: "KnitNote Backup",
                value: "Wrong English backup description"
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("macOS Info.plist has no English source fallback"))
    }

    @Test func archiveAuditRejectsWrongDirectEnglishInfoPlistFallbackEvenWhenCompiledTableMasksIt() throws {
        let fixture = try makeArchiveFixture(
            englishInfoPlistFallbackOverride: (
                target: "iOS",
                key: "NSCameraUsageDescription",
                value: "Wrong camera purpose"
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("iOS Info.plist has no English source fallback"))
        #expect(result.output.contains("NSCameraUsageDescription"))
    }

    @Test func archiveAuditRejectsBackupFallbackLiteralAtTheWrongPlistPath() throws {
        let fixture = try makeArchiveFixture(
            englishInfoPlistFallbackOverride: (
                target: "macOS",
                key: "KnitNote Backup",
                value: "Wrong backup description"
            ),
            misplacedEnglishInfoPlistFallback: (
                target: "macOS",
                key: "KnitNote Backup"
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("macOS Info.plist has no English source fallback"))
        #expect(result.output.contains("KnitNote Backup"))
    }

    @Test func archiveAuditRejectsEachMissingOrChangedMacSecurityEntitlement() throws {
        let keys = [
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.network.client",
        ]
        for key in keys {
            for mutation in ["missing", "changed"] {
                let fixture = try makeArchiveFixture(
                    missingMacSignedEntitlement: mutation == "missing" ? key : nil,
                    changedMacSignedEntitlement: mutation == "changed" ? key : nil
                )
                defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

                let result = try runReleaseAudit(
                    archives: fixture.archives,
                    environment: ["PATH": fixture.commandPath]
                )

                #expect(result.status != 0)
                #expect(
                    result.output.contains(
                        "macOS signed entitlements do not match the production security contract"
                    )
                )
            }
        }
    }

    @Test func archiveAuditRejectsUnexpectedMacSecurityEntitlement() throws {
        let fixture = try makeArchiveFixture(
            extraMacSignedEntitlement: "com.apple.security.cs.allow-jit"
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(
            result.output.contains(
                "macOS signed entitlements do not match the production security contract"
            )
        )
    }

    @Test func archiveAuditRejectsUnexpectedMacDeveloperEntitlement() throws {
        let fixture = try makeArchiveFixture(
            extraMacSignedEntitlement: "aps-environment"
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(
            result.output.contains(
                "macOS signed entitlements do not match the production security contract"
            )
        )
    }

    @Test func archiveAuditAcceptsRealUTF16LEMacStringsAndPreservesItsExactKeyDomain() throws {
        let fixture = try makeArchiveFixture(utf16Localization: ("macOS", "el"))
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(result.output.contains("TEST FIXTURE ARCHIVE AUDIT: PASS"))
    }

    @Test func archiveAuditUsesTheSupportedJoinedCertificateExtractionOption() throws {
        let script = try String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/release_audit.sh"),
            encoding: .utf8
        )
        #expect(script.contains("\"--extract-certificates=$cert_prefix\""))
        #expect(!script.contains("--extract-certificates \"$cert_prefix\""))
    }

    @Test func archiveAuditRejectsUTF16LEMacStringsWithAKeyDomainDrift() throws {
        let fixture = try makeArchiveFixture(
            utf16Localization: ("macOS", "el"),
            missingLocalizationKey: ("macOS", "el")
        )
        defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }

        let result = try runReleaseAudit(
            archives: fixture.archives,
            environment: ["PATH": fixture.commandPath]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("macOS el compiled localization key domain differs from source"))
    }

    @Test func archiveAuditRejectsWrongRevisionEmptyLocalePrivacyDriftAndWrongSigning() throws {
        let cases: [(ArchiveFixture, String)] = [
            (try makeArchiveFixture(sourceRevision: String(repeating: "b", count: 40)), "product source revision"),
            (try makeArchiveFixture(emptyResource: ("Watch", "el")), "Localizable.strings is not a valid compiled localization table"),
            (try makeArchiveFixture(privacyTracking: true), "declares tracking or collected data"),
            (try makeArchiveFixture(privacyReasonDrift: true), "differs semantically from source"),
            (try makeArchiveFixture(signingTeam: "BADTEAM123"), "signature team is not 9CFPAUL5N5"),
            (try makeArchiveFixture(profileIdentifierOverride: "9CFPAUL5N5.com.phillon.WrongApp"), "provisioning profile is expired or is not App Store distribution"),
            (try makeArchiveFixture(profileCertificate: "different-certificate"), "signing certificate is not present"),
            (try makeArchiveFixture(provenancePathOverride: "../unrelated"), "provenance sourceCommit or deterministic archive inventory mismatch"),
            (try makeArchiveFixture(mutateAfterProvenance: true), "deterministic archive inventory mismatch"),
            (try makeArchiveFixture(profileExpired: true), "provisioning profile is expired"),
            (try makeArchiveFixture(profileMissing: true), "embedded provisioning profile is missing"),
            (try makeArchiveFixture(codesignFailure: true), "signature verification failed"),
            (try makeArchiveFixture(signedIdentifierOverride: "9CFPAUL5N5.com.phillon.WrongApp"), "signed entitlements do not match"),
            (try makeArchiveFixture(gitHead: String(repeating: "b", count: 40)), "expected source revision does not match"),
            (try makeArchiveFixture(dirtySource: true), "source worktree is dirty"),
        ]
        for (fixture, expected) in cases {
            defer { try? FileManager.default.removeItem(at: fixture.temporaryRoot) }
            let result = try runReleaseAudit(archives: fixture.archives, environment: ["PATH": fixture.commandPath])
            #expect(result.status != 0)
            #expect(result.output.contains(expected))
        }
    }

    @Test func staticAuditUsesAStaticOnlySuccessMarker() throws {
        let result = try runReleaseAudit()
        let outputLines = result.output
            .split(separator: "\n")
            .map(String.init)

        #expect(result.status == 0)
        #expect(outputLines.contains("STATIC RELEASE AUDIT: PASS"))
        #expect(!outputLines.contains("RELEASE AUDIT: PASS"))
    }

    @Test func productionAuditRejectsFixtureOverridesBeforeEmittingAPassMarker() throws {
        let result = try runReleaseAudit(
            arguments: ["--static-only"],
            environment: [:],
            productionEnvironment: ["KNITNOTE_AUDIT_GIT_ROOT": "/tmp/unrelated"]
        )
        #expect(result.status != 0)
        #expect(result.output.contains("production audit rejects override KNITNOTE_AUDIT_GIT_ROOT"))
        #expect(!result.output.contains("RELEASE AUDIT: PASS"))
    }

    @Test func localAppStoreExportOptionsAreAutomaticLocalAndPreserveBuildIdentity() throws {
        let url = releaseAuditRepositoryRoot.appendingPathComponent(
            "AppStore/Verification/ExportOptions-AppStore.plist"
        )
        let data = try #require(try? Data(contentsOf: url))
        let options = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(Set(options.keys) == [
            "destination",
            "manageAppVersionAndBuildNumber",
            "method",
            "signingStyle",
            "teamID",
        ])
        #expect(options["destination"] as? String == "export")
        #expect(options["method"] as? String == "app-store-connect")
        #expect(options["signingStyle"] as? String == "automatic")
        #expect(options["teamID"] as? String == "9CFPAUL5N5")
        #expect(options["manageAppVersionAndBuildNumber"] as? Bool == false)
    }

    @Test func supportedCandidateCreatorExportsBothArchivesBeforeProvenanceAuditAndPublication() throws {
        let script = try candidateCreatorScript()
        #expect(script.contains("worktree add --detach"))
        #expect(script.components(separatedBy: "\"$XCODEBUILD\" -project KnitNote.xcodeproj").count - 1 == 2)
        #expect(script.components(separatedBy: "\"$XCODEBUILD\" -exportArchive").count - 1 == 2)
        #expect(script.components(separatedBy: "KNITNOTE_SOURCE_REVISION=\"$COMMIT\" archive").count - 1 == 2)
        let iOSArchive = try #require(releaseArchiveCommand(in: script, platform: "iOS"))
        let macOSArchive = try #require(releaseArchiveCommand(in: script, platform: "macOS"))
        let iOSExport = try #require(releaseExportCommand(in: script, platform: "iOS"))
        let macOSExport = try #require(releaseExportCommand(in: script, platform: "macOS"))
        let iOSArchiveRange = try #require(script.range(of: iOSArchive))
        let macOSArchiveRange = try #require(script.range(of: macOSArchive))
        let iOSExportRange = try #require(script.range(of: iOSExport))
        let macOSExportRange = try #require(script.range(of: macOSExport))
        let provenance = try #require(script.range(of: "release_archive_manifest.py\" create"))
        let audit = try #require(script.range(of: "release_audit.sh --archives"))
        let publication = try #require(script.range(of: "\"$PUBLISHER\" --cleanup-dir \"$WORKROOT\" \"$ARTIFACTS\" \"$FINAL\""))

        #expect(iOSArchiveRange.lowerBound < iOSExportRange.lowerBound)
        #expect(macOSArchiveRange.lowerBound < iOSExportRange.lowerBound)
        #expect(iOSArchiveRange.lowerBound < macOSExportRange.lowerBound)
        #expect(macOSArchiveRange.lowerBound < macOSExportRange.lowerBound)
        #expect(iOSExportRange.lowerBound < provenance.lowerBound)
        #expect(macOSExportRange.lowerBound < provenance.lowerBound)
        #expect(provenance.lowerBound < audit.lowerBound)
        #expect(audit.lowerBound < publication.lowerBound)
    }

    @Test func candidateCreatorForbidsUploadAndProvisioningUpdates() throws {
        let script = executableBash(try candidateCreatorScript())
        #expect(!script.contains("-allowProvisioningUpdates"))
        #expect(!script.contains("destination=upload"))
        #expect(!script.contains("CODE_SIGN_STYLE=Manual"))
        #expect(!script.contains("CODE_SIGN_IDENTITY=\"Apple Distribution\""))
        #expect(!script.contains("PROVISIONING_PROFILE_SPECIFIER"))
    }

    @Test func candidateCreatorBindsProductionXcodebuildAndPermitsOverridesOnlyInTestMode() throws {
        let script = try candidateCreatorScript()
        #expect(script.contains("XCODEBUILD=/usr/bin/xcodebuild"))
        #expect(script.contains("MKTEMP=mktemp"))
        #expect(script.contains("if [[ \"$TEST_ONLY\" == 1 ]]; then"))
        #expect(script.contains("XCODEBUILD=\"${KNITNOTE_CREATOR_XCODEBUILD:-$XCODEBUILD}\""))
        for variable in ["KNITNOTE_CREATOR_XCODEBUILD", "KNITNOTE_CREATOR_MKTEMP"] {
            let production = try runCandidateCreator(arguments: ["/tmp/unused-candidate"], environment: [variable: "/tmp/override"])
            #expect(production.status != 0)
            #expect(production.output.contains("release candidate creation rejects override \(variable)"))
        }
    }

    @Test func atomicPublicationNeverNestsArtifactsAndRejectsDestinationRace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("knitnote-atomic-publish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging")
        let final = root.appendingPathComponent("candidate")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("candidate artifact".utf8).write(to: staging.appendingPathComponent("artifact.txt"))

        let first = try runAtomicPublish(staging: staging, final: final)
        #expect(first.status == 0, Comment(rawValue: first.output))
        #expect(FileManager.default.fileExists(atPath: final.appendingPathComponent("artifact.txt").path))
        #expect(!FileManager.default.fileExists(atPath: final.appendingPathComponent("artifacts").path))

        let racedStaging = root.appendingPathComponent("raced-staging")
        let racedFinal = root.appendingPathComponent("raced-candidate")
        try FileManager.default.createDirectory(at: racedStaging, withIntermediateDirectories: true)
        try Data("candidate artifact".utf8).write(to: racedStaging.appendingPathComponent("artifact.txt"))
        try FileManager.default.createDirectory(at: racedFinal, withIntermediateDirectories: true)
        let raced = try runAtomicPublish(staging: racedStaging, final: racedFinal)
        #expect(raced.status != 0)
        #expect(raced.output.contains("candidate destination appeared during exclusive publication"))
        #expect(FileManager.default.fileExists(atPath: racedStaging.appendingPathComponent("artifact.txt").path))
        #expect(!FileManager.default.fileExists(atPath: racedFinal.appendingPathComponent("artifacts").path))
    }

    @Test func creatorFixturePublishesPrivateCandidateWithoutRawPackagingLogsAndCleansRaceStaging() throws {
        let successful = try runCreatorFixture(raceDestination: false)
        defer { try? FileManager.default.removeItem(at: successful.root) }
        #expect(successful.result.status == 0, Comment(rawValue: successful.result.output))
        #expect(successful.result.output.contains("TEST ONLY: release candidate fixture created at"))
        #expect(!successful.result.output.contains("Release candidate created at"))
        #expect(FileManager.default.fileExists(atPath: successful.final.path))
        #expect(!FileManager.default.fileExists(atPath: successful.final.appendingPathComponent("Distribution/iOS/Packaging.log").path))
        #expect(!FileManager.default.fileExists(atPath: successful.final.appendingPathComponent("Distribution/macOS/Packaging.log").path))
        #expect(FileManager.default.fileExists(atPath: successful.final.appendingPathComponent(".TEST_FIXTURE_NOT_FOR_RELEASE").path))
        let successfulRemaining = try FileManager.default.contentsOfDirectory(atPath: successful.parent.path)
        #expect(!successfulRemaining.contains(where: { $0.hasPrefix(".KnitNote-1.7.0.staging.") || $0.hasPrefix(".KnitNote-1.7.0.worktree.") }))
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: successful.final.path)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue & 0o077 == 0)
        let observedMasks = try String(contentsOf: successful.umaskLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(observedMasks == ["0022", "0022", "0022", "0022"])

        let raced = try runCreatorFixture(raceDestination: true)
        defer { try? FileManager.default.removeItem(at: raced.root) }
        #expect(raced.result.status != 0)
        #expect(!raced.result.output.contains("Release candidate created at"))
        #expect(raced.result.output.contains("candidate destination appeared during exclusive publication"))
        #expect(!FileManager.default.fileExists(atPath: raced.final.appendingPathComponent("artifacts").path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: raced.parent.path)
        #expect(!remaining.contains(where: { $0.hasPrefix(".KnitNote-1.7.0.staging.") }))

        let cleanupFailure = try runCreatorFixture(raceDestination: false, cleanupFailure: true)
        defer { try? FileManager.default.removeItem(at: cleanupFailure.root) }
        #expect(cleanupFailure.result.status != 0)
        #expect(!cleanupFailure.result.output.contains("Release candidate created at"))
        #expect(!FileManager.default.fileExists(atPath: cleanupFailure.final.path))
        let cleanupRemaining = try FileManager.default.contentsOfDirectory(atPath: cleanupFailure.parent.path)
        #expect(!cleanupRemaining.contains(where: { $0.hasPrefix(".KnitNote-1.7.0.staging.") || $0.hasPrefix(".KnitNote-1.7.0.worktree.") }))

        let secondMktempFailure = try runCreatorFixture(raceDestination: false, secondMktempFailure: true)
        defer { try? FileManager.default.removeItem(at: secondMktempFailure.root) }
        #expect(secondMktempFailure.result.status != 0)
        #expect(!FileManager.default.fileExists(atPath: secondMktempFailure.final.path))
        let mktempRemaining = try FileManager.default.contentsOfDirectory(atPath: secondMktempFailure.parent.path)
        #expect(!mktempRemaining.contains(where: { $0.hasPrefix(".KnitNote-1.7.0.staging.") || $0.hasPrefix(".KnitNote-1.7.0.worktree.") }))
    }

    @Test func distributionSigningContractUsesTheExpectedTeamForEveryReleaseArchive() throws {
        let sources = try distributionSigningContractSources()

        #expect(distributionSigningContractIssues(
            specification: sources.specification,
            generatedProject: sources.generatedProject,
            script: sources.script
        ).isEmpty)
        #expect(distributionSigningContractIssues(
            specification: sources.specification,
            generatedProject: sources.generatedProject,
            script: sources.script.replacingOccurrences(of: "MKTEMP=mktemp", with: "MKTEMP=/tmp/mktemp")
        ).contains("production temporary directory tool"))
    }

    @Test func distributionSigningContractRejectsMisboundAutomaticArchivesExportsAndPreflight() throws {
        let sources = try distributionSigningContractSources()
        let projectDebug = try #require(generatedBuildConfiguration(
            in: sources.generatedProject,
            owner: #"PBXProject "KnitNote""#,
            configuration: "Debug"
        ))
        let projectRelease = try #require(generatedBuildConfiguration(
            in: sources.generatedProject,
            owner: #"PBXProject "KnitNote""#,
            configuration: "Release"
        ))
        let watchRelease = try #require(generatedBuildConfiguration(
            in: sources.generatedProject,
            owner: #"PBXNativeTarget "KnitNoteWatch""#,
            configuration: "Release"
        ))

        let generatedMutations = [
            (
                section: projectDebug,
                setting: "CODE_SIGN_STYLE = Automatic;",
                replacement: "CODE_SIGN_STYLE = Manual;",
                issue: "project Debug signing style"
            ),
            (
                section: projectRelease,
                setting: "CODE_SIGN_STYLE = Automatic;",
                replacement: "CODE_SIGN_STYLE = Manual;",
                issue: "project Release signing style"
            ),
            (
                section: watchRelease,
                setting: "CODE_SIGN_IDENTITY = \"Apple Development\";",
                replacement: "CODE_SIGN_IDENTITY = \"Apple Distribution\";",
                issue: "KnitNoteWatch Release signing identity"
            ),
        ]
        for mutation in generatedMutations {
            #expect(mutation.section.contains(mutation.setting))
            let mutatedSection = mutation.section.replacingOccurrences(
                of: mutation.setting,
                with: mutation.replacement
            )
            let mutatedProject = sources.generatedProject.replacingOccurrences(
                of: mutation.section,
                with: mutatedSection
            )
            #expect(distributionSigningContractIssues(
                specification: sources.specification,
                generatedProject: mutatedProject,
                script: sources.script
            ).contains(mutation.issue))
        }

        let iOSCommand = try #require(releaseArchiveCommand(in: sources.script, platform: "iOS"))
        let macOSCommand = try #require(releaseArchiveCommand(in: sources.script, platform: "macOS"))
        let manualIOSCommand = iOSCommand.replacingOccurrences(
            of: "KNITNOTE_SOURCE_REVISION=\"$COMMIT\" archive)",
            with: "CODE_SIGN_STYLE=Manual KNITNOTE_SOURCE_REVISION=\"$COMMIT\" archive)"
        )
        #expect(distributionSigningContractIssues(
            specification: sources.specification,
            generatedProject: sources.generatedProject,
            script: sources.script.replacingOccurrences(of: iOSCommand, with: manualIOSCommand)
        ).contains("iOS archive signing override"))
        let overrides = "CODE_SIGN_STYLE=Manual"
        let duplicateIOSCommand = iOSCommand.replacingOccurrences(
            of: "KNITNOTE_SOURCE_REVISION=\"$COMMIT\" archive)",
            with: "\(overrides) \\\n  \(overrides) KNITNOTE_SOURCE_REVISION=\"$COMMIT\" archive)"
        )
        let unsignedMacOSCommand = macOSCommand.replacingOccurrences(
            of: "KNITNOTE_SOURCE_REVISION=\"$COMMIT\" ",
            with: ""
        )
        let globallyBalancedOverrides = sources.script
            .replacingOccurrences(of: iOSCommand, with: duplicateIOSCommand)
            .replacingOccurrences(of: macOSCommand, with: unsignedMacOSCommand)
        #expect(globallyBalancedOverrides.components(separatedBy: overrides).count - 1 == 2)
        let commandIssues = distributionSigningContractIssues(
            specification: sources.specification,
            generatedProject: sources.generatedProject,
            script: globallyBalancedOverrides
        )
        #expect(commandIssues.contains("iOS archive signing override"))
        #expect(commandIssues.contains("macOS archive source revision"))

        for decoy in [
            "# \(overrides)",
            "if false; then\n  : '\(overrides)'\nfi",
        ] {
            let decoyBalancedOverrides = sources.script
                .replacingOccurrences(of: macOSCommand, with: unsignedMacOSCommand)
                .appending("\n\(decoy)\n")
            #expect(decoyBalancedOverrides.components(separatedBy: overrides).count - 1 == 1)
            #expect(distributionSigningContractIssues(
                specification: sources.specification,
                generatedProject: sources.generatedProject,
                script: decoyBalancedOverrides
            ).contains("macOS archive source revision"))
        }

        let iOSExport = try #require(releaseExportCommand(in: sources.script, platform: "iOS"))
        let macOSExport = try #require(releaseExportCommand(in: sources.script, platform: "macOS"))
        let wrongIOSExportPath = iOSExport.replacingOccurrences(
            of: "$ARTIFACTS/Distribution/iOS",
            with: "$ARTIFACTS/Distribution/macOS"
        )
        #expect(distributionSigningContractIssues(
            specification: sources.specification,
            generatedProject: sources.generatedProject,
            script: sources.script.replacingOccurrences(of: iOSExport, with: wrongIOSExportPath)
        ).contains("iOS export command"))
        let provisioningMacOSExport = macOSExport.replacingOccurrences(
            of: "-exportArchive",
            with: "-allowProvisioningUpdates -exportArchive"
        )
        #expect(distributionSigningContractIssues(
            specification: sources.specification,
            generatedProject: sources.generatedProject,
            script: sources.script.replacingOccurrences(of: macOSExport, with: provisioningMacOSExport)
        ).contains("forbidden upload or provisioning update flag"))

        let preflight = try #require(distributionIdentityPreflight(in: sources.script))
        let withoutPreflight = sources.script.replacingOccurrences(of: "\(preflight)\n\n", with: "")
        let staging = try #require(withoutPreflight.range(of: "ARTIFACTS=\"$(\"$MKTEMP\""))
        let stagingLineEnd = try #require(withoutPreflight.range(
            of: "\n",
            range: staging.upperBound..<withoutPreflight.endIndex
        ))
        let latePreflight = String(withoutPreflight[..<staging.lowerBound])
            + "# /usr/bin/security find-identity -v -p codesigning\n"
            + String(withoutPreflight[staging.lowerBound..<stagingLineEnd.upperBound])
            + "\(preflight)\n"
            + String(withoutPreflight[stagingLineEnd.upperBound...])
        let preflightIssues = distributionSigningContractIssues(
            specification: sources.specification,
            generatedProject: sources.generatedProject,
            script: latePreflight
        )
        #expect(preflightIssues.contains("distribution identity preflight before staging"))
    }

    @Test func distributionSigningContractRejectsAnArchiveCommandInAnUnreachableBranch() throws {
        let sources = try distributionSigningContractSources()
        let macOSCommand = try #require(releaseArchiveCommand(in: sources.script, platform: "macOS"))
        let deadMacOSArchive = "if false; then\n  \(macOSCommand)\nfi"
        let scriptWithDeadMacOSArchive = sources.script.replacingOccurrences(
            of: macOSCommand,
            with: deadMacOSArchive
        )

        let issues = distributionSigningContractIssues(
            specification: sources.specification,
            generatedProject: sources.generatedProject,
            script: scriptWithDeadMacOSArchive
        )

        #expect(issues.contains("macOS archive command"))
    }

    @Test func distributionSigningContractRejectsTargetStyleOverridesAndProfilesInEveryConfiguration() throws {
        let sources = try distributionSigningContractSources()
        let targets = [
            (
                label: "KnitNote",
                generatedOwner: #"PBXNativeTarget "KnitNote""#,
                specificationStart: "  KnitNote:\n",
                specificationEnd: "  KnitNoteWatch:\n"
            ),
            (
                label: "KnitNoteWatch",
                generatedOwner: #"PBXNativeTarget "KnitNoteWatch""#,
                specificationStart: "  KnitNoteWatch:\n",
                specificationEnd: "  KnitNoteShare:\n"
            ),
            (
                label: "KnitNoteShare",
                generatedOwner: #"PBXNativeTarget "KnitNoteShare""#,
                specificationStart: "  KnitNoteShare:\n",
                specificationEnd: "  KnitNoteAppTests:\n"
            ),
        ]

        for target in targets {
            for configuration in ["Debug", "Release"] {
                let generatedMutation = try #require(generatedProjectByAddingBuildSetting(
                    sources.generatedProject,
                    owner: target.generatedOwner,
                    configuration: configuration,
                    setting: "CODE_SIGN_STYLE = Manual;"
                ))
                #expect(distributionSigningContractIssues(
                    specification: sources.specification,
                    generatedProject: generatedMutation,
                    script: sources.script
                ).contains("\(target.label) \(configuration) target signing style override"))

                let specificationMutation = try #require(specificationByAddingTargetBuildSetting(
                    sources.specification,
                    targetStart: target.specificationStart,
                    targetEnd: target.specificationEnd,
                    configuration: configuration,
                    setting: "CODE_SIGN_STYLE: Manual"
                ))
                #expect(distributionSigningContractIssues(
                    specification: specificationMutation,
                    generatedProject: sources.generatedProject,
                    script: sources.script
                ).contains("\(target.label) \(configuration) target signing style specification override"))
            }
        }

        let profileMutations = [
            (
                target: targets[0],
                generatedSetting: "PROVISIONING_PROFILE_SPECIFIER = WrongDebugProfile;",
                specificationSetting: "PROVISIONING_PROFILE_SPECIFIER: WrongDebugProfile"
            ),
            (
                target: targets[0],
                generatedSetting: "\"PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]\" = WrongDebugProfile;",
                specificationSetting: "\"PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]\": WrongDebugProfile"
            ),
            (
                target: targets[0],
                generatedSetting: "\"PROVISIONING_PROFILE_SPECIFIER[sdk=macosx*]\" = WrongDebugProfile;",
                specificationSetting: "\"PROVISIONING_PROFILE_SPECIFIER[sdk=macosx*]\": WrongDebugProfile"
            ),
            (
                target: targets[1],
                generatedSetting: "PROVISIONING_PROFILE_SPECIFIER = WrongDebugProfile;",
                specificationSetting: "PROVISIONING_PROFILE_SPECIFIER: WrongDebugProfile"
            ),
            (
                target: targets[2],
                generatedSetting: "PROVISIONING_PROFILE_SPECIFIER = WrongDebugProfile;",
                specificationSetting: "PROVISIONING_PROFILE_SPECIFIER: WrongDebugProfile"
            ),
        ]
        for mutation in profileMutations {
            for configuration in ["Debug", "Release"] {
                let generatedMutation = try #require(generatedProjectByAddingBuildSetting(
                    sources.generatedProject,
                    owner: mutation.target.generatedOwner,
                    configuration: configuration,
                    setting: mutation.generatedSetting
                ))
                #expect(distributionSigningContractIssues(
                    specification: sources.specification,
                    generatedProject: generatedMutation,
                    script: sources.script
                ).contains("\(mutation.target.label) \(configuration) provisioning profile"))

                let specificationMutation = try #require(specificationByAddingTargetBuildSetting(
                    sources.specification,
                    targetStart: mutation.target.specificationStart,
                    targetEnd: mutation.target.specificationEnd,
                    configuration: configuration,
                    setting: mutation.specificationSetting
                ))
                #expect(distributionSigningContractIssues(
                    specification: specificationMutation,
                    generatedProject: sources.generatedProject,
                    script: sources.script
                ).contains("\(mutation.target.label) \(configuration) provisioning profile specification"))
            }
        }
    }

    @Test func auditRejectsMissingContradictoryAndRepeatedModes() throws {
        for arguments in [
            [],
            ["--static-only", "--archives", "/tmp/unused-archives"],
            ["--static-only", "--static-only"],
            ["--archives", "/tmp/first", "--archives", "/tmp/second"],
        ] {
            let result = try runReleaseAudit(arguments: arguments)
            let outputLines = result.output
                .split(separator: "\n")
                .map(String.init)

            #expect(result.status == 2)
            #expect(result.output.contains("usage: release_audit.sh"))
            #expect(!outputLines.contains("STATIC RELEASE AUDIT: PASS"))
            #expect(!outputLines.contains("RELEASE AUDIT: PASS"))
        }
    }
}

private struct DistributionSigningContractSources {
    let specification: String
    let generatedProject: String
    let script: String
}

private func candidateCreatorScript() throws -> String {
    try String(
        contentsOf: releaseAuditRepositoryRoot.appendingPathComponent(
            "AppStore/Verification/create_release_candidate.sh"
        ),
        encoding: .utf8
    )
}

private func runCandidateCreator(arguments: [String], environment overrides: [String: String]) throws -> AuditResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["AppStore/Verification/create_release_candidate.sh"] + arguments
    process.currentDirectoryURL = releaseAuditRepositoryRoot
    process.environment = ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return AuditResult(
        status: process.terminationStatus,
        output: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

private func distributionSigningContractSources() throws -> DistributionSigningContractSources {
    try DistributionSigningContractSources(
        specification: String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        ),
        generatedProject: String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("KnitNote.xcodeproj/project.pbxproj"),
            encoding: .utf8
        ),
        script: String(
            contentsOf: releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/create_release_candidate.sh"),
            encoding: .utf8
        )
    )
}

private func distributionSigningContractIssues(
    specification: String,
    generatedProject: String,
    script: String
) -> [String] {
    var issues: [String] = []
    let expectedIdentities = [
        (configuration: "Debug", identity: "Apple Development"),
        (configuration: "Release", identity: "Apple Development"),
    ]
    let specificationOwners = [
        (label: "project", start: "settings:\n", end: "targets:\n"),
        (label: "KnitNote", start: "  KnitNote:\n", end: "  KnitNoteWatch:\n"),
        (label: "KnitNoteWatch", start: "  KnitNoteWatch:\n", end: "  KnitNoteShare:\n"),
        (label: "KnitNoteShare", start: "  KnitNoteShare:\n", end: "  KnitNoteAppTests:\n"),
    ]
    for owner in specificationOwners {
        guard let ownerSection = sourceSection(in: specification, start: owner.start, end: owner.end) else {
            issues.append("\(owner.label) signing specification section")
            continue
        }
        for expected in expectedIdentities where !ownerSection.contains(
            "    \(expected.configuration):\n      CODE_SIGN_IDENTITY: \(expected.identity)"
        ) && !ownerSection.contains(
            "        \(expected.configuration):\n          CODE_SIGN_IDENTITY: \(expected.identity)"
        ) {
            issues.append("\(owner.label) \(expected.configuration) signing specification")
        }
    }
    if !specification.contains("DEVELOPMENT_TEAM: 9CFPAUL5N5") {
        issues.append("expected development team")
    }
    if let projectSpecification = sourceSection(
        in: specification,
        start: "settings:\n",
        end: "targets:\n"
    ) {
        if !projectSpecification.contains(
            "    Debug:\n      CODE_SIGN_IDENTITY: Apple Development\n      CODE_SIGN_STYLE: Automatic"
        ) {
            issues.append("project Debug signing style specification")
        }
        if !projectSpecification.contains(
            "    Release:\n      CODE_SIGN_IDENTITY: Apple Development\n      CODE_SIGN_STYLE: Automatic"
        ) {
            issues.append("project Release signing style specification")
        }
    }
    for owner in specificationOwners.dropFirst() {
        guard let ownerSection = sourceSection(
            in: specification,
            start: owner.start,
            end: owner.end
        ) else {
            continue
        }
        for configurationName in ["Debug", "Release"] {
            guard let configuration = sourceTargetBuildConfiguration(
                in: ownerSection,
                configuration: configurationName
            ) else {
                continue
            }
            if configuration.contains("CODE_SIGN_STYLE:") {
                issues.append("\(owner.label) \(configurationName) target signing style specification override")
            }
            if configuration.contains("PROVISIONING_PROFILE_SPECIFIER") {
                issues.append("\(owner.label) \(configurationName) provisioning profile specification")
            }
        }
    }

    let generatedOwners = [
        (label: "project", owner: #"PBXProject "KnitNote""#),
        (label: "KnitNote", owner: #"PBXNativeTarget "KnitNote""#),
        (label: "KnitNoteWatch", owner: #"PBXNativeTarget "KnitNoteWatch""#),
        (label: "KnitNoteShare", owner: #"PBXNativeTarget "KnitNoteShare""#),
    ]
    for owner in generatedOwners {
        for expected in expectedIdentities {
            let configuration = generatedBuildConfiguration(
                in: generatedProject,
                owner: owner.owner,
                configuration: expected.configuration
            )
            if configuration?.contains("CODE_SIGN_IDENTITY = \"\(expected.identity)\";") != true {
                issues.append("\(owner.label) \(expected.configuration) signing identity")
            }
            if owner.label != "project", configuration?.contains("CODE_SIGN_STYLE") == true {
                issues.append("\(owner.label) \(expected.configuration) target signing style override")
            }
            if owner.label != "project",
               configuration?.contains("PROVISIONING_PROFILE_SPECIFIER") == true {
                issues.append("\(owner.label) \(expected.configuration) provisioning profile")
            }
        }
    }

    let projectStyles = [
        (configuration: "Debug", style: "Automatic"),
        (configuration: "Release", style: "Automatic"),
    ]
    for expected in projectStyles {
        let configuration = generatedBuildConfiguration(
            in: generatedProject,
            owner: #"PBXProject "KnitNote""#,
            configuration: expected.configuration
        )
        if configuration?.contains("CODE_SIGN_STYLE = \(expected.style);") != true {
            issues.append("project \(expected.configuration) signing style")
        }
    }
    let generatedProfiles = [
        (
            label: "KnitNote Release iOS provisioning profile",
            owner: #"PBXNativeTarget "KnitNote""#,
            setting: "\"PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]\" = \"iOS Team Store Provisioning Profile: com.phillon.KnitNote\";"
        ),
        (
            label: "KnitNote Release macOS provisioning profile",
            owner: #"PBXNativeTarget "KnitNote""#,
            setting: "\"PROVISIONING_PROFILE_SPECIFIER[sdk=macosx*]\" = \"Mac Team Store Provisioning Profile: com.phillon.KnitNote\";"
        ),
        (
            label: "KnitNoteWatch Release provisioning profile",
            owner: #"PBXNativeTarget "KnitNoteWatch""#,
            setting: "PROVISIONING_PROFILE_SPECIFIER = \"iOS Team Store Provisioning Profile: com.phillon.KnitNote.watch\";"
        ),
        (
            label: "KnitNoteShare Release provisioning profile",
            owner: #"PBXNativeTarget "KnitNoteShare""#,
            setting: "PROVISIONING_PROFILE_SPECIFIER = \"iOS Team Store Provisioning Profile: com.phillon.KnitNote.share\";"
        ),
    ]
    for expected in generatedProfiles {
        let configuration = generatedBuildConfiguration(
            in: generatedProject,
            owner: expected.owner,
            configuration: "Release"
        )
        if configuration?.contains(expected.setting) == true {
            issues.append(expected.label)
        }
    }

    for platform in ["iOS", "macOS"] {
        guard let command = releaseArchiveCommand(in: script, platform: platform) else {
            issues.append("\(platform) archive command")
            continue
        }
        let normalized = normalizedExecutableBash(command)
        let expectedPath = platform == "iOS"
            ? "KnitNote-iOS-Privacy.xcarchive"
            : "KnitNote-macOS-Privacy.xcarchive"
        if !normalized.contains("generic/platform=\(platform)")
            || !normalized.contains(expectedPath) {
            issues.append("\(platform) archive command")
        }
        if !normalized.contains("KNITNOTE_SOURCE_REVISION=\"$COMMIT\" archive)") {
            issues.append("\(platform) archive source revision")
        }
        if normalized.contains("CODE_SIGN_STYLE=")
            || normalized.contains("CODE_SIGN_IDENTITY=")
            || normalized.contains("PROVISIONING_PROFILE_SPECIFIER") {
            issues.append("\(platform) archive signing override")
        }
    }

    for platform in ["iOS", "macOS"] {
        guard let command = releaseExportCommand(in: script, platform: platform) else {
            issues.append("\(platform) export command")
            continue
        }
        let normalized = normalizedExecutableBash(command)
        let archiveName = platform == "iOS"
            ? "KnitNote-iOS-Privacy.xcarchive"
            : "KnitNote-macOS-Privacy.xcarchive"
        if !normalized.contains("\"$XCODEBUILD\" -exportArchive")
            || !normalized.contains("-archivePath \"$ARTIFACTS/\(archiveName)\"")
            || !normalized.contains("-exportPath \"$ARTIFACTS/Distribution/\(platform)\"")
            || !normalized.contains("-exportOptionsPlist \"$WORKTREE/AppStore/Verification/ExportOptions-AppStore.plist\"") {
            issues.append("\(platform) export command")
        }
    }

    let executableScript = executableBash(script)
    if !executableScript.contains("XCODEBUILD=/usr/bin/xcodebuild") {
        issues.append("production Xcode build tool")
    }
    if !executableScript.contains("MKTEMP=mktemp") {
        issues.append("production temporary directory tool")
    }
    if executableScript.contains("-allowProvisioningUpdates")
        || executableScript.contains("destination=upload") {
        issues.append("forbidden upload or provisioning update flag")
    }
    if !executableScript.contains("EXPECTED_TEAM=9CFPAUL5N5") {
        issues.append("expected distribution signing team")
    }
    if !executableScript.contains("SECURITY=/usr/bin/security")
        || distributionIdentityPreflight(in: executableScript)?.contains(
            #"/usr/bin/grep -Eq "Apple Distribution:.*\($EXPECTED_TEAM\)""#
        ) != true {
        issues.append("expected distribution identity predicate")
    }
    let dirtyGuard = "[[ -z \"$($GIT -C \"$ROOT\" status --porcelain --untracked-files=normal)\" ]] || { echo \"candidate worktree is dirty\" >&2; exit 1; }"
    let parent = "PARENT=\"$(cd \"$(dirname \"$OUTPUT\")\" && pwd -P)\""
    let staging = "ARTIFACTS=\"$(\"$MKTEMP\""
    if let dirtyRange = executableScript.range(of: dirtyGuard),
       let preflight = distributionIdentityPreflight(in: executableScript),
       let preflightRange = executableScript.range(of: preflight),
       let parentRange = executableScript.range(of: parent),
       let stagingRange = executableScript.range(of: staging),
       dirtyRange.upperBound < preflightRange.lowerBound,
       preflightRange.upperBound < parentRange.lowerBound,
       parentRange.upperBound < stagingRange.lowerBound,
       executableScript[dirtyRange.upperBound..<preflightRange.lowerBound]
           .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       executableScript[preflightRange.upperBound..<parentRange.lowerBound]
           .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        // The executable preflight is top-level and precedes staging.
    } else {
        issues.append("distribution identity preflight before staging")
    }
    return issues
}

private func sourceSection(in source: String, start: String, end: String) -> String? {
    guard let startRange = source.range(of: start),
          let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        return nil
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private func sourceTargetBuildConfiguration(
    in targetSection: String,
    configuration: String
) -> String? {
    let marker = "        \(configuration):\n"
    guard let start = targetSection.range(of: marker) else {
        return nil
    }
    let end: String.Index
    if configuration == "Debug",
       let release = targetSection.range(
           of: "        Release:\n",
           range: start.upperBound..<targetSection.endIndex
       ) {
        end = release.lowerBound
    } else {
        end = targetSection.endIndex
    }
    return String(targetSection[start.lowerBound..<end])
}

private func generatedBuildConfiguration(
    in project: String,
    owner: String,
    configuration: String
) -> String? {
    let listMarker = "/* Build configuration list for \(owner) */ = {"
    guard let listStart = project.range(of: listMarker),
          let listEnd = project.range(
            of: "\n\t\t};",
            range: listStart.upperBound..<project.endIndex
          ) else {
        return nil
    }
    let list = project[listStart.lowerBound..<listEnd.upperBound]
    guard let configurationLine = list.split(separator: "\n").first(where: {
        $0.contains("/* \(configuration) */")
    }), let identifier = configurationLine.split(whereSeparator: { $0.isWhitespace }).first else {
        return nil
    }
    let configurationMarker = "\t\t\(identifier) /* \(configuration) */ = {"
    guard let configurationStart = project.range(of: configurationMarker),
          let configurationEnd = project.range(
            of: "\n\t\t};",
            range: configurationStart.upperBound..<project.endIndex
          ) else {
        return nil
    }
    return String(project[configurationStart.lowerBound..<configurationEnd.upperBound])
}

private func generatedConfigurationList(in project: String, owner: String) -> String? {
    let marker = "/* Build configuration list for \(owner) */ = {"
    guard let start = project.range(of: marker),
          let end = project.range(of: "\n\t\t};", range: start.upperBound..<project.endIndex) else {
        return nil
    }
    return String(project[start.lowerBound..<end.upperBound])
}

private func generatedOwnerObject(in project: String, owner: String) -> String? {
    if owner.hasPrefix("PBXProject") {
        guard let start = project.range(of: "/* Project object */ = {"),
              let end = project.range(of: "\n\t\t};", range: start.upperBound..<project.endIndex) else {
            return nil
        }
        return String(project[start.lowerBound..<end.upperBound])
    }
    let name = owner
        .replacingOccurrences(of: #"PBXNativeTarget ""#, with: "")
        .replacingOccurrences(of: #"""#, with: "")
    let marker = "/* \(name) */ = {\n\t\t\tisa = PBXNativeTarget;"
    guard let start = project.range(of: marker),
          let lineStart = project[..<start.lowerBound].lastIndex(of: "\n"),
          let end = project.range(of: "\n\t\t};", range: start.upperBound..<project.endIndex) else {
        return nil
    }
    return String(project[project.index(after: lineStart)..<end.upperBound])
}

private func mutatePBXGraph(_ project: String, mutation: PBXGraphMutation) throws -> String {
    switch mutation.kind {
    case .rootClass:
        let object = try #require(generatedOwnerObject(in: project, owner: mutation.owner))
        let changed = try #require(object.replacingFirstOccurrence(
            of: "isa = PBXProject;",
            with: "isa = PBXGroup;"
        ))
        return project.replacingOccurrences(of: object, with: changed)
    case .targetClass:
        let object = try #require(generatedOwnerObject(in: project, owner: mutation.owner))
        let changed = try #require(object.replacingFirstOccurrence(
            of: "isa = PBXNativeTarget;",
            with: "isa = PBXAggregateTarget;"
        ))
        return project.replacingOccurrences(of: object, with: changed)
    case .targetProductName:
        let object = try #require(generatedOwnerObject(in: project, owner: mutation.owner))
        let changed = try #require(object.replacingFirstOccurrence(
            of: "productName = ",
            with: "productName = Decoy-"
        ))
        return project.replacingOccurrences(of: object, with: changed)
    case .duplicateTarget:
        let object = try #require(generatedOwnerObject(in: project, owner: mutation.owner))
        let firstIdentifier = try #require(object.split(whereSeparator: { $0.isWhitespace }).first)
        let decoyIdentifier = "D00D\(String(firstIdentifier).dropFirst(4))"
        let clone = object.replacingOccurrences(of: String(firstIdentifier), with: decoyIdentifier)
        let sectionEnd = try #require(project.range(of: "/* End PBXNativeTarget section */"))
        var changed = project
        changed.insert(contentsOf: clone + "\n", at: sectionEnd.lowerBound)
        let root = try #require(generatedOwnerObject(in: changed, owner: #"PBXProject "KnitNote""#))
        let targets = try #require(root.range(of: "targets = (\n"))
        var changedRoot = root
        changedRoot.insert(contentsOf: "\t\t\t\t\(decoyIdentifier) /* decoy */,\n", at: targets.upperBound)
        return changed.replacingOccurrences(of: root, with: changedRoot)
    case .configurationListClass:
        let list = try #require(generatedConfigurationList(in: project, owner: mutation.owner))
        let changed = try #require(list.replacingFirstOccurrence(
            of: "isa = XCConfigurationList;",
            with: "isa = PBXGroup;"
        ))
        return project.replacingOccurrences(of: list, with: changed)
    case .configurationClass:
        let configurationName = try #require(mutation.configuration)
        let configuration = try #require(generatedBuildConfiguration(
            in: project,
            owner: mutation.owner,
            configuration: configurationName
        ))
        let changed = try #require(configuration.replacingFirstOccurrence(
            of: "isa = XCBuildConfiguration;",
            with: "isa = PBXGroup;"
        ))
        return project.replacingOccurrences(of: configuration, with: changed)
    case .danglingConfigurationList:
        let object = try #require(generatedOwnerObject(in: project, owner: mutation.owner))
        let expression = try NSRegularExpression(pattern: #"buildConfigurationList = [A-F0-9]+"#)
        let range = NSRange(object.startIndex..<object.endIndex, in: object)
        let changed = expression.stringByReplacingMatches(
            in: object,
            range: range,
            withTemplate: "buildConfigurationList = DEADBEEFDEADBEEFDEADBEEF"
        )
        return project.replacingOccurrences(of: object, with: changed)
    case .danglingConfiguration:
        let list = try #require(generatedConfigurationList(in: project, owner: mutation.owner))
        let configuration = try #require(mutation.configuration)
        let expression = try NSRegularExpression(pattern: #"[A-F0-9]+ /\* "# + configuration + #" \*/"#)
        let range = NSRange(list.startIndex..<list.endIndex, in: list)
        let changed = expression.stringByReplacingMatches(
            in: list,
            range: range,
            withTemplate: "DEADBEEFDEADBEEFDEADBEEF /* \(configuration) */"
        )
        return project.replacingOccurrences(of: list, with: changed)
    case .danglingTarget:
        let root = try #require(generatedOwnerObject(in: project, owner: mutation.owner))
        let targets = try #require(root.range(of: "targets = (\n"))
        var changed = root
        changed.insert(contentsOf: "\t\t\t\tDEADBEEFDEADBEEFDEADBEEF /* missing */,\n", at: targets.upperBound)
        return project.replacingOccurrences(of: root, with: changed)
    }
}

private func generatedProjectByDuplicatingBuildSetting(
    _ project: String,
    mutation: PBXDuplicateSettingMutation
) -> String? {
    guard let original = generatedBuildConfiguration(
        in: project,
        owner: mutation.owner,
        configuration: mutation.configuration
    ) else {
        return nil
    }
    let lines = original.split(separator: "\n", omittingEmptySubsequences: false)
    guard let canonicalLine = lines.first(where: {
        $0.contains(mutation.key) && $0.contains(mutation.canonicalValue)
    }) else {
        return nil
    }
    let evilLine = "\t\t\t\t\(mutation.syntax.spelling(mutation.key)) = \(mutation.evilValue);"
    let replacement: String
    switch mutation.order {
    case .evilFirst:
        replacement = evilLine + "\n" + canonicalLine
    case .evilLast:
        replacement = String(canonicalLine) + "\n" + evilLine
    }
    let changed = original.replacingOccurrences(of: String(canonicalLine), with: replacement)
    return project.replacingOccurrences(of: original, with: changed)
}

private func generatedProjectByAddingBuildSetting(
    _ project: String,
    owner: String,
    configuration: String,
    setting: String
) -> String? {
    guard let original = generatedBuildConfiguration(
        in: project,
        owner: owner,
        configuration: configuration
    ), let insertion = original.range(of: "buildSettings = {\n") else {
        return nil
    }
    var mutated = original
    mutated.insert(contentsOf: "\t\t\t\t\(setting)\n", at: insertion.upperBound)
    return project.replacingOccurrences(of: original, with: mutated)
}

private func specificationByAddingTargetBuildSetting(
    _ specification: String,
    targetStart: String,
    targetEnd: String,
    configuration: String,
    setting: String
) -> String? {
    guard let original = sourceSection(
        in: specification,
        start: targetStart,
        end: targetEnd
    ), let insertion = original.range(of: "        \(configuration):\n") else {
        return nil
    }
    var mutated = original
    mutated.insert(contentsOf: "          \(setting)\n", at: insertion.upperBound)
    return specification.replacingOccurrences(of: original, with: mutated)
}

private func releaseArchiveCommand(in script: String, platform: String) -> String? {
    let destination = "-destination 'generic/platform=\(platform)'"
    let topLevelScript = topLevelExecutableBash(script)
    guard let destinationRange = topLevelScript.range(of: destination),
          let commandStart = topLevelScript[..<destinationRange.lowerBound].range(
            of: "(cd \"$WORKTREE\" && \"$XCODEBUILD\"",
            options: .backwards
          ),
          let commandEnd = topLevelScript.range(
            of: "archive)",
            range: destinationRange.upperBound..<topLevelScript.endIndex
          ) else {
        return nil
    }
    return String(topLevelScript[commandStart.lowerBound..<commandEnd.upperBound])
}

private func releaseExportCommand(in script: String, platform: String) -> String? {
    let archiveName = platform == "iOS"
        ? "KnitNote-iOS-Privacy.xcarchive"
        : "KnitNote-macOS-Privacy.xcarchive"
    let archivePath = "-archivePath \"$ARTIFACTS/\(archiveName)\""
    let exportPath = "-exportPath \"$ARTIFACTS/Distribution/\(platform)\""
    let endMarker = "ExportOptions-AppStore.plist\")"
    let topLevelScript = topLevelExecutableBash(script)
    guard let exportRange = topLevelScript.range(of: exportPath),
          let commandStart = topLevelScript[..<exportRange.lowerBound].range(
            of: "(cd \"$WORKTREE\" && \"$XCODEBUILD\" -exportArchive",
            options: .backwards
          ),
          topLevelScript.range(
            of: archivePath,
            range: commandStart.upperBound..<exportRange.lowerBound
          ) != nil,
          let commandEnd = topLevelScript.range(
            of: endMarker,
            range: exportRange.upperBound..<topLevelScript.endIndex
          ) else {
        return nil
    }
    return String(topLevelScript[commandStart.lowerBound..<commandEnd.upperBound])
}

private func distributionIdentityPreflight(in script: String) -> String? {
    let start = "if ! \"$SECURITY\" find-identity -v -p codesigning"
    guard let startRange = script.range(of: start),
          let endRange = script.range(of: "\nfi", range: startRange.upperBound..<script.endIndex) else {
        return nil
    }
    return String(script[startRange.lowerBound..<endRange.upperBound])
}

private func executableBash(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        let sourceLine = String(line)
        return sourceLine.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? "" : sourceLine
    }.joined(separator: "\n")
}

private func topLevelExecutableBash(_ source: String) -> String {
    var controlDepth = 0
    return executableBash(source)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in
            let sourceLine = String(line)
            let trimmed = sourceLine.trimmingCharacters(in: .whitespaces)
            if ["fi", "done", "esac", "}"].contains(trimmed) {
                controlDepth = max(0, controlDepth - 1)
                return ""
            }
            if isBashControlBlockStart(trimmed) {
                controlDepth += 1
                return ""
            }
            return controlDepth == 0 ? sourceLine : ""
        }
        .joined(separator: "\n")
}

private func isBashControlBlockStart(_ line: String) -> Bool {
    line.hasPrefix("if ")
        || line.hasPrefix("for ")
        || line.hasPrefix("while ")
        || line.hasPrefix("until ")
        || line.hasPrefix("case ")
        || line.hasSuffix("() {")
}

private func normalizedExecutableBash(_ source: String) -> String {
    executableBash(source)
        .replacingOccurrences(of: "\\\n", with: " ")
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
}

private struct AuditResult {
    let status: Int32
    let output: String
}

private struct ArchiveFixture {
    let temporaryRoot: URL
    let archives: URL
    let macPackageApp: URL
    let commandPath: String
    let provenance: URL
    let extractionLog: URL
}

private let fixtureCommit = String(repeating: "a", count: 40)

private struct BundleFixture {
    let name: String
    let bundle: URL
    let resources: URL
    let infoPlist: URL
    let identifier: String
    let companionIdentifier: String?
}

private let releaseLocales = [
    "en", "zh-Hant", "zh-Hans", "de", "fr", "ja",
    "nb", "sv", "fi", "da", "ko", "el", "nl",
]

private func runStaticAudit(projectArchiveSchemaSource sourceText: String) throws -> AuditResult {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("knitnote-project-archive-schema-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    let source = temporaryRoot.appendingPathComponent("ProjectArchiveSchema.swift")
    try sourceText.write(to: source, atomically: true, encoding: .utf8)
    return try runReleaseAudit(
        environment: ["KNITNOTE_PROJECT_ARCHIVE_SCHEMA_SOURCE": source.path]
    )
}

private func runStaticAudit(projectFileSource sourceText: String) throws -> AuditResult {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("knitnote-entitlement-project-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    let source = temporaryRoot.appendingPathComponent("project.pbxproj")
    try sourceText.write(to: source, atomically: true, encoding: .utf8)
    return try runReleaseAudit(environment: ["KNITNOTE_PROJECT_FILE": source.path])
}

private struct SourceInfoPlistFixture {
    let root: URL
    let main: URL
    let watch: URL
}

private struct ProjectSpecFixture {
    let root: URL
    let xcodegen: URL
}

private func projectSpecFixture(
    mutate: (inout [String: Any]) throws -> Void
) throws -> ProjectSpecFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("knitnote-project-spec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(filePath: "/opt/homebrew/bin/xcodegen")
    process.arguments = ["dump", "--type", "parsed-json"]
    process.currentDirectoryURL = releaseAuditRepositoryRoot
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    var specification = try #require(
        JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile())
            as? [String: Any]
    )
    try mutate(&specification)
    let json = root.appendingPathComponent("project.json")
    try JSONSerialization.data(withJSONObject: specification).write(to: json)
    let xcodegen = root.appendingPathComponent("xcodegen")
    try """
    #!/bin/sh
    cat '\(json.path)'
    """.write(to: xcodegen, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: xcodegen.path
    )
    return ProjectSpecFixture(root: root, xcodegen: xcodegen)
}

private func sourceInfoPlistFixture(
    mainModes: [String]?,
    watchModes: [String]? = nil,
    decoyModes: [String]? = nil
) throws -> SourceInfoPlistFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("knitnote-source-info-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func mutatedPlist(_ relativePath: String, modes: [String]?) throws -> [String: Any] {
        let data = try Data(contentsOf: releaseAuditRepositoryRoot.appendingPathComponent(relativePath))
        var plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        plist["UIBackgroundModes"] = modes
        return plist
    }
    let main = root.appendingPathComponent("Main.plist")
    let watch = root.appendingPathComponent("Watch.plist")
    try writePlist(try mutatedPlist("KnitNote/Info.plist", modes: mainModes), to: main)
    try writePlist(try mutatedPlist("KnitNoteWatch/Info.plist", modes: watchModes), to: watch)
    if let decoyModes {
        try writePlist(
            try mutatedPlist("KnitNote/Info.plist", modes: decoyModes),
            to: root.appendingPathComponent("CloudKitRemoteNotificationDecoy.plist")
        )
    }
    return SourceInfoPlistFixture(root: root, main: main, watch: watch)
}

private extension String {
    func replacingFirstOccurrence(of target: String, with replacement: String) -> String? {
        guard let range = range(of: target) else { return nil }
        return replacingCharacters(in: range, with: replacement)
    }
}

private func runReleaseAudit(
    archives: URL? = nil,
    arguments: [String]? = nil,
    environment overrides: [String: String] = [:],
    productionEnvironment: [String: String]? = nil
) throws -> AuditResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    let modeArguments = arguments ?? archives.map {
        ["--archives", $0.path,
         "--expected-commit", fixtureCommit,
         "--provenance", $0.appendingPathComponent("provenance.json").path]
    } ?? ["--static-only"]
    let isFixture = productionEnvironment == nil && (archives != nil || !overrides.isEmpty)
    process.arguments = ["AppStore/Verification/release_audit.sh"] + (isFixture ? ["--test-only"] : []) + modeArguments
    process.currentDirectoryURL = releaseAuditRepositoryRoot
    let requestedEnvironment = productionEnvironment ?? overrides
    var environment = ProcessInfo.processInfo.environment.merging(requestedEnvironment) { _, new in new }
    if let commandPath = overrides["PATH"]?.split(separator: ":").first.map(String.init) {
        environment["KNITNOTE_GIT"] = "\(commandPath)/git"
        environment["KNITNOTE_CODESIGN"] = "\(commandPath)/codesign"
        environment["KNITNOTE_SECURITY"] = "\(commandPath)/security"
        environment["KNITNOTE_SWIFT"] = "\(commandPath)/swift"
        environment["KNITNOTE_DITTO"] = "\(commandPath)/ditto"
        environment["KNITNOTE_PKGUTIL"] = "\(commandPath)/pkgutil"
    }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()
    return AuditResult(
        status: process.terminationStatus,
        output: String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    )
}

private func runManifest(
    _ command: String,
    archives: URL,
    provenance: URL,
    exportOptions: URL
) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3",
        releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/release_archive_manifest.py").path,
        command,
        "--archives", archives.path,
        "--source-commit", fixtureCommit,
        command == "create" ? "--output" : "--input", provenance.path,
        "--export-options", exportOptions.path,
    ]
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func runAtomicPublish(staging: URL, final: URL) throws -> AuditResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3",
        releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/atomic_publish.py").path,
        staging.path,
        final.path,
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return AuditResult(
        status: process.terminationStatus,
        output: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

private func runCreatorFixture(raceDestination: Bool, cleanupFailure: Bool = false, secondMktempFailure: Bool = false) throws -> (result: AuditResult, root: URL, parent: URL, final: URL, umaskLog: URL) {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("knitnote-creator-fixture-\(UUID().uuidString)")
    let parent = root.appendingPathComponent("output")
    let bin = root.appendingPathComponent("bin")
    let final = parent.appendingPathComponent("candidate")
    let umaskLog = root.appendingPathComponent("xcodebuild-umasks.log")
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
    let realRoot = releaseAuditRepositoryRoot.path
    let fixtureVerification = root.appendingPathComponent("AppStore/Verification")
    try fileManager.createDirectory(at: fixtureVerification, withIntermediateDirectories: true)
    try fileManager.copyItem(
        at: releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/atomic_publish.py"),
        to: fixtureVerification.appendingPathComponent("atomic_publish.py")
    )
    let commit = fixtureCommit
    func executable(_ name: String, _ body: String) throws -> URL {
        let path = bin.appendingPathComponent(name)
        try body.write(to: path, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: path.path)
        return path
    }
    let git = try executable("git", """
    #!/bin/bash
    case "$*" in
      *"rev-parse --show-toplevel"*) printf '%s\\n' '\(root.path)' ;;
      *"rev-parse HEAD"*) printf '%s\\n' '\(commit)' ;;
      *"status --porcelain"*) : ;;
      *"worktree add"*)
        worktree="${@: -2:1}"
        mkdir -p "$worktree/AppStore/Verification"
        cp '\(realRoot)/AppStore/Verification/atomic_publish.py' "$worktree/AppStore/Verification/atomic_publish.py"
        printf '#!/bin/sh\\nexit 0\\n' > "$worktree/AppStore/Verification/release_audit.sh"
        chmod 700 "$worktree/AppStore/Verification/release_audit.sh" ;;
      *"worktree remove"*)
        [ "\(cleanupFailure ? "yes" : "no")" = "yes" ] && exit 73
        worktree="${@: -1}"
        rm -rf "$worktree" ;;
      *) exit 64 ;;
    esac
    """)
    let security = try executable("security", "#!/bin/sh\nprintf '%s\\n' '1) Apple Distribution: Fixture (9CFPAUL5N5)'\n")
    let xcodebuild = try executable("xcodebuild", """
    #!/bin/bash
    umask >> '\(umaskLog.path)'
    export_path=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-exportPath" ]]; then export_path="$2"; shift 2; continue; fi
      shift
    done
    if [[ -n "$export_path" ]]; then
      mkdir -p "$export_path"
      printf 'raw packaging fixture\\n' > "$export_path/Packaging.log"
    fi
    """)
    let python = try executable("python", """
    #!/bin/bash
    if [[ "$1" == *release_archive_manifest.py ]]; then
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--output" ]]; then : > "$2"; exit 0; fi
        shift
      done
      exit 64
    fi
    exec /usr/bin/python3 "$@"
    """)
    let hook = try executable("race", "#!/bin/sh\nmkdir -p \"$1\"\n")
    let mktemp = try executable("mktemp", """
    #!/bin/bash
    count='\(root.path)/mktemp-count'
    if [ -e "$count" ]; then exit 74; fi
    : > "$count"
    exec /usr/bin/mktemp "$@"
    """)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/create_release_candidate.sh").path,
        "--test-only", final.path,
    ]
    process.currentDirectoryURL = releaseAuditRepositoryRoot
    var environment = ProcessInfo.processInfo.environment
    environment["KNITNOTE_CREATOR_ROOT"] = root.path
    environment["KNITNOTE_CREATOR_GIT"] = git.path
    environment["KNITNOTE_CREATOR_SECURITY"] = security.path
    environment["KNITNOTE_CREATOR_XCODEBUILD"] = xcodebuild.path
    environment["KNITNOTE_CREATOR_PYTHON"] = python.path
    if secondMktempFailure { environment["KNITNOTE_CREATOR_MKTEMP"] = mktemp.path }
    if raceDestination { environment["KNITNOTE_CREATOR_TEST_BEFORE_PUBLISH"] = hook.path }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return (
        AuditResult(status: process.terminationStatus, output: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""),
        root,
        parent,
        final,
        umaskLog
    )
}

private func signedCloudEntitlements(
    for product: SignedCloudEntitlementMutation.Product,
    mutation: SignedCloudEntitlementMutation?
) -> String {
    let applies = mutation?.product == product
    if product == .watch || product == .share {
        guard applies else { return "" }
        switch mutation?.kind {
        case .extraContainer:
            return "<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.com.phillon.KnitNote</string></array>"
        case .extraServices:
            return "<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>"
        case .extraEnvironment:
            return "<key>com.apple.developer.icloud-container-environment</key><string>Production</string>"
        case .extraIOSAPS:
            return "<key>aps-environment</key><string>production</string>"
        case .extraMacAPS:
            return "<key>com.apple.developer.aps-environment</key><string>production</string>"
        default:
            return ""
        }
    }

    let kind = applies ? mutation?.kind : nil
    let containers: String
    switch kind {
    case .missingContainer:
        containers = ""
    case .wrongContainer:
        containers = "<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.com.phillon.Wrong</string></array>"
    case .extraContainer:
        containers = "<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.com.phillon.KnitNote</string><string>iCloud.com.phillon.Unexpected</string></array>"
    default:
        containers = "<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.com.phillon.KnitNote</string></array>"
    }
    let services: String
    switch kind {
    case .missingServices:
        services = ""
    case .wrongServices:
        services = "<key>com.apple.developer.icloud-services</key><array><string>CloudDocuments</string></array>"
    case .extraServices:
        services = "<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string><string>CloudDocuments</string></array>"
    default:
        services = "<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>"
    }
    let environment: String
    switch kind {
    case .missingEnvironment:
        environment = ""
    case .wrongEnvironment:
        environment = "<key>com.apple.developer.icloud-container-environment</key><string>Development</string>"
    case .extraEnvironment:
        environment = "<key>com.apple.developer.icloud-container-environment</key><array><string>Production</string><string>Development</string></array>"
    default:
        environment = "<key>com.apple.developer.icloud-container-environment</key><string>Production</string>"
    }
    let apsKey = product == .iOS ? "aps-environment" : "com.apple.developer.aps-environment"
    let aps: String
    switch kind {
    case .missingAPS:
        aps = ""
    case .wrongAPS:
        aps = "<key>\(apsKey)</key><string>development</string>"
    case .extraAPS:
        let alternate = product == .iOS ? "com.apple.developer.aps-environment" : "aps-environment"
        aps = "<key>\(apsKey)</key><string>production</string><key>\(alternate)</key><string>production</string>"
    default:
        aps = "<key>\(apsKey)</key><string>production</string>"
    }
    return """
    \(containers)
    \(services)
    \(environment)
    \(aps)
    """
}

private func conflictingSignedIdentifierAlias(
    for product: SignedCloudEntitlementMutation.Product,
    mutation: SignedCloudEntitlementMutation?
) -> String {
    guard mutation?.product == product, mutation?.kind == .conflictingIdentifierAlias else {
        return ""
    }
    let key = product == .macOS ? "application-identifier" : "com.apple.application-identifier"
    return "<key>\(key)</key><string>9CFPAUL5N5.\(product == .watch ? "com.phillon.KnitNote.watch" : product == .share ? "com.phillon.KnitNote.share" : "com.phillon.KnitNote")</string>"
}

private func identifierKeys(
    for product: ProductIdentifierMutation.Product
) -> (canonical: String, alternate: String, bundle: String) {
    let bundle: String
    switch product {
    case .iOS, .macOS: bundle = "com.phillon.KnitNote"
    case .watch: bundle = "com.phillon.KnitNote.watch"
    case .share: bundle = "com.phillon.KnitNote.share"
    }
    return product == .macOS
        ? ("com.apple.application-identifier", "application-identifier", bundle)
        : ("application-identifier", "com.apple.application-identifier", bundle)
}

private func identifierValues(
    for product: ProductIdentifierMutation.Product,
    location: ProductIdentifierMutation.Location,
    mutation: ProductIdentifierMutation?,
    canonicalOverride: String? = nil
) -> [String: String] {
    let keys = identifierKeys(for: product)
    let expected = canonicalOverride ?? "9CFPAUL5N5.\(keys.bundle)"
    guard mutation?.product == product, mutation?.location == location else {
        return [keys.canonical: expected]
    }
    switch mutation?.kind {
    case .missingCanonical:
        return [:]
    case .alternateOnly:
        return [keys.alternate: expected]
    case .extraCorrectAlias:
        return [keys.canonical: expected, keys.alternate: expected]
    case .extraConflictingAlias:
        return [keys.canonical: expected, keys.alternate: "9CFPAUL5N5.com.phillon.Conflicting"]
    case nil:
        return [keys.canonical: expected]
    }
}

private func identifierXML(_ values: [String: String]) -> String {
    values.keys.sorted().map { key in
        "<key>\(key)</key><string>\(values[key]!)</string>"
    }.joined()
}

private func makeArchiveFixture(
    omittingDirectory: (target: String, locale: String)? = nil,
    extraDirectory: (target: String, locale: String)? = nil,
    localizationOverrides: [String: [String]] = [:],
    version: String = "1.7.0",
    build: String = "13",
    sourceRevision: String = fixtureCommit,
    emptyResource: (String, String)? = nil,
    privacyTracking: Bool = false,
    privacyReasonDrift: Bool = false,
    signingTeam: String = "9CFPAUL5N5",
    profileIdentifierOverride: String? = nil,
    profileCertificate: String = "certificate",
    macProfileGetTaskAllow: Bool? = false,
    provenancePathOverride: String? = nil,
    gitHead: String = fixtureCommit,
    dirtySource: Bool = false,
    mutateAfterProvenance: Bool = false,
    profileExpired: Bool = false,
    profileMissing: Bool = false,
    codesignFailure: Bool = false,
    signedIdentifierOverride: String? = nil,
    utf16Localization: (target: String, locale: String)? = nil,
    missingLocalizationKey: (target: String, locale: String)? = nil,
    omittingInfoPlistTable: (target: String, locale: String)? = nil,
    infoPlistValueOverride: (target: String, locale: String, key: String, value: String)? = nil,
    extraInfoPlistKey: (target: String, locale: String)? = nil,
    englishInfoPlistFallbackOverride: (target: String, key: String, value: String)? = nil,
    misplacedEnglishInfoPlistFallback: (target: String, key: String)? = nil,
    missingMacSignedEntitlement: String? = nil,
    changedMacSignedEntitlement: String? = nil,
    extraMacSignedEntitlement: String? = nil,
    signedCloudEntitlementMutation: SignedCloudEntitlementMutation? = nil,
    identifierMutation: ProductIdentifierMutation? = nil,
    mutateDistributionAfterProvenance: String? = nil,
    removeDistributionAfterProvenance: String? = nil,
    extractionFailure: String? = nil,
    pkgutilRejectsExistingDestination: Bool = false,
    packageSignature: String = "valid",
    extraDistributionBeforeProvenance: String? = nil,
    testFixtureSentinelBeforeProvenance: Bool = false,
    omitPreparedExportRoot: String? = nil,
    ambiguousMacApps: Bool = false,
    rejectArchiveCodesign: Bool = false,
    symlinkDistributionAfterProvenance: String? = nil,
    symlinkPreparedExportRoot: String? = nil,
    symlinkPreparedIOSPayloadToReal: Bool = false,
    symlinkDistributionParentAfterProvenance: Bool = false
) throws -> ArchiveFixture {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("knitnote-release-audit-\(UUID().uuidString)")
    let archives = temporaryRoot.appendingPathComponent("archives")
    let iOSApp = archives.appendingPathComponent(
        "KnitNote-iOS-Privacy.xcarchive/Products/Applications/KnitNote.app"
    )
    let macApp = archives.appendingPathComponent(
        "KnitNote-macOS-Privacy.xcarchive/Products/Applications/KnitNote.app"
    )
    let bundles = [
        BundleFixture(
            name: "iOS",
            bundle: iOSApp,
            resources: iOSApp,
            infoPlist: iOSApp.appendingPathComponent("Info.plist"),
            identifier: "com.phillon.KnitNote",
            companionIdentifier: nil
        ),
        BundleFixture(
            name: "Watch",
            bundle: iOSApp.appendingPathComponent("Watch/KnitNoteWatch.app"),
            resources: iOSApp.appendingPathComponent("Watch/KnitNoteWatch.app"),
            infoPlist: iOSApp.appendingPathComponent("Watch/KnitNoteWatch.app/Info.plist"),
            identifier: "com.phillon.KnitNote.watch",
            companionIdentifier: "com.phillon.KnitNote"
        ),
        BundleFixture(
            name: "Share",
            bundle: iOSApp.appendingPathComponent("PlugIns/KnitNoteShare.appex"),
            resources: iOSApp.appendingPathComponent("PlugIns/KnitNoteShare.appex"),
            infoPlist: iOSApp.appendingPathComponent("PlugIns/KnitNoteShare.appex/Info.plist"),
            identifier: "com.phillon.KnitNote.share",
            companionIdentifier: nil
        ),
        BundleFixture(
            name: "macOS",
            bundle: macApp,
            resources: macApp.appendingPathComponent("Contents/Resources"),
            infoPlist: macApp.appendingPathComponent("Contents/Info.plist"),
            identifier: "com.phillon.KnitNote",
            companionIdentifier: nil
        ),
    ]

    for item in bundles {
        try fileManager.createDirectory(at: item.resources, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": item.identifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleLocalizations": localizationOverrides[item.name] ?? releaseLocales,
            "KnitNoteSourceRevision": sourceRevision,
        ]
        if item.name == "iOS" || item.name == "macOS" {
            plist["CFBundleDisplayName"] = "KnitNote"
            plist["CFBundleName"] = "KnitNote"
            plist["NSCameraUsageDescription"] = "Take photos for knitting projects, journal entries, and yarn labels."
            if let override = englishInfoPlistFallbackOverride,
               override.target == item.name,
               override.key != "KnitNote Backup" {
                plist[override.key] = override.value
            }
            let backupDescription = englishInfoPlistFallbackOverride?.target == item.name
                && englishInfoPlistFallbackOverride?.key == "KnitNote Backup"
                ? englishInfoPlistFallbackOverride?.value ?? "KnitNote Backup"
                : "KnitNote Backup"
            plist["UTExportedTypeDeclarations"] = [[
                "UTTypeDescription": backupDescription,
                "UTTypeIdentifier": "com.phillon.KnitNote.backup",
            ]]
            if let misplaced = misplacedEnglishInfoPlistFallback,
               misplaced.target == item.name {
                plist["FixtureMisplacedEnglishFallback"] = misplaced.key
            }
        }
        if let companionIdentifier = item.companionIdentifier {
            plist["WKCompanionAppBundleIdentifier"] = companionIdentifier
        }
        try writePlist(plist, to: item.infoPlist)
        var localizationDirectories = releaseLocales + ["Base"]
        if extraDirectory?.target == item.name, let extraLocale = extraDirectory?.locale {
            localizationDirectories.append(extraLocale)
        }
        for locale in localizationDirectories
        where !(omittingDirectory?.target == item.name && omittingDirectory?.locale == locale) {
            try fileManager.createDirectory(
                at: item.resources.appendingPathComponent("\(locale).lproj"),
                withIntermediateDirectories: true
            )
            let catalog: String
            switch item.name {
            case "Watch": catalog = "KnitNoteWatch/Localizable.xcstrings"
            case "Share": catalog = "KnitNoteShare/Localizable.xcstrings"
            default: catalog = "KnitNote/Localization/Localizable.xcstrings"
            }
            let catalogData = try Data(contentsOf: releaseAuditRepositoryRoot.appendingPathComponent(catalog))
            let catalogJSON = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
            let strings = try #require(catalogJSON["strings"] as? [String: Any])
            var localizedValues = Dictionary(uniqueKeysWithValues: strings.keys.map { ($0, "localized") })
            if missingLocalizationKey?.target == item.name && missingLocalizationKey?.locale == locale,
               let removedKey = localizedValues.keys.sorted().first {
                localizedValues.removeValue(forKey: removedKey)
            }
            try writePlist(localizedValues, to: item.resources.appendingPathComponent("\(locale).lproj/Localizable.strings"))
            if utf16Localization?.target == item.name && utf16Localization?.locale == locale {
                try writeUTF16LEStrings(localizedValues, to: item.resources.appendingPathComponent("\(locale).lproj/Localizable.strings"))
            }
            if emptyResource?.0 == item.name && emptyResource?.1 == locale {
                try Data().write(to: item.resources.appendingPathComponent("\(locale).lproj/Localizable.strings"))
            }
            if (item.name == "iOS" || item.name == "macOS"),
               locale != "Base",
               !(omittingInfoPlistTable?.target == item.name && omittingInfoPlistTable?.locale == locale) {
                var infoValues = try compiledInfoPlistValues(locale: locale)
                if locale == "en" {
                    infoValues = infoValues.filter { $0.key == "NSCameraUsageDescription" }
                }
                if infoPlistValueOverride?.target == item.name,
                   infoPlistValueOverride?.locale == locale,
                   let key = infoPlistValueOverride?.key,
                   let value = infoPlistValueOverride?.value {
                    infoValues[key] = value
                }
                if extraInfoPlistKey?.target == item.name,
                   extraInfoPlistKey?.locale == locale {
                    infoValues["UnexpectedSystemString"] = "Unexpected"
                }
                try writePlist(
                    infoValues,
                    to: item.resources.appendingPathComponent("\(locale).lproj/InfoPlist.strings")
                )
            }
        }
        let sourcePrivacy: String
        switch item.name {
        case "Watch": sourcePrivacy = "KnitNoteWatch/PrivacyInfo.xcprivacy"
        case "Share": sourcePrivacy = "KnitNoteShare/PrivacyInfo.xcprivacy"
        default: sourcePrivacy = "KnitNote/PrivacyInfo.xcprivacy"
        }
        let privacyData = try Data(contentsOf: releaseAuditRepositoryRoot.appendingPathComponent(sourcePrivacy))
        var privacy = try #require(
            PropertyListSerialization.propertyList(from: privacyData, format: nil) as? [String: Any]
        )
        privacy["NSPrivacyTracking"] = privacyTracking
        if privacyReasonDrift, item.name == "iOS",
           var APIs = privacy["NSPrivacyAccessedAPITypes"] as? [[String: Any]], !APIs.isEmpty {
            APIs[0]["NSPrivacyAccessedAPITypeReasons"] = ["WRONG.1"]
            privacy["NSPrivacyAccessedAPITypes"] = APIs
        }
        try writePlist(privacy, to: item.resources.appendingPathComponent("PrivacyInfo.xcprivacy"))
        let profile = item.name == "macOS"
            ? item.bundle.appendingPathComponent("Contents/embedded.provisionprofile")
            : item.bundle.appendingPathComponent("embedded.mobileprovision")
        let product: ProductIdentifierMutation.Product
        switch item.name {
        case "iOS": product = .iOS
        case "macOS": product = .macOS
        case "Watch": product = .watch
        case "Share": product = .share
        default: throw CocoaError(.validationMissingMandatoryProperty)
        }
        var profileEntitlements: [String: Any] = identifierValues(
            for: product,
            location: .profile,
            mutation: identifierMutation,
            canonicalOverride: profileIdentifierOverride
        )
        if item.name == "macOS" {
            if let macProfileGetTaskAllow {
                profileEntitlements["get-task-allow"] = macProfileGetTaskAllow
            }
        } else {
            profileEntitlements["get-task-allow"] = false
        }
        if item.name == "iOS" || item.name == "Share" {
            profileEntitlements["com.apple.security.application-groups"] = ["group.com.phillon.KnitNote"]
        }
        try writePlist(
            [
                "TeamIdentifier": ["9CFPAUL5N5"],
                "Entitlements": profileEntitlements,
                "DeveloperCertificates": [Data(profileCertificate.utf8)],
                "ExpirationDate": profileExpired ? Date(timeIntervalSince1970: 0) : Date(timeIntervalSince1970: 4_102_444_800),
            ],
            to: profile
        )
    }

    let artifacts: [(String, URL)] = [
        ("ios", iOSApp.appendingPathComponent("KnitNote")),
        ("watch", iOSApp.appendingPathComponent("Watch/KnitNoteWatch.app/KnitNoteWatch")),
        ("share", iOSApp.appendingPathComponent("PlugIns/KnitNoteShare.appex/KnitNoteShare")),
        ("macos", macApp.appendingPathComponent("Contents/MacOS/KnitNote")),
    ]
    for (_, file) in artifacts {
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: file)
    }

    if profileMissing {
        try fileManager.removeItem(at: iOSApp.appendingPathComponent("embedded.mobileprovision"))
    }

    let preparedIOS = temporaryRoot.appendingPathComponent("prepared-ios")
    let preparedIOSApp = preparedIOS.appendingPathComponent("Payload/KnitNote.app")
    let preparedMac = temporaryRoot.appendingPathComponent("prepared-mac")
    let preparedMacApp = preparedMac.appendingPathComponent(
        "com.phillon.KnitNote.pkg/Payload/KnitNote.app"
    )
    try fileManager.createDirectory(at: preparedIOS, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: preparedMac, withIntermediateDirectories: true)
    if omitPreparedExportRoot != "iOS" {
        try fileManager.createDirectory(
            at: preparedIOSApp.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: iOSApp, to: preparedIOSApp)
    }
    if omitPreparedExportRoot != "macOS" {
        try fileManager.createDirectory(
            at: preparedMacApp.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: macApp, to: preparedMacApp)
    }
    if ambiguousMacApps {
        let second = preparedMac.appendingPathComponent("other.pkg/Payload/KnitNote.app")
        try fileManager.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: macApp, to: second)
    }
    if symlinkPreparedIOSPayloadToReal {
        let payload = preparedIOS.appendingPathComponent("Payload")
        let real = preparedIOS.appendingPathComponent("real")
        try fileManager.moveItem(at: payload, to: real)
        try fileManager.createSymbolicLink(atPath: payload.path, withDestinationPath: "real")
    }
    if symlinkPreparedExportRoot == "iOS" {
        try fileManager.removeItem(at: preparedIOSApp)
        try fileManager.createSymbolicLink(at: preparedIOSApp, withDestinationURL: iOSApp)
    } else if symlinkPreparedExportRoot == "macOS" {
        try fileManager.removeItem(at: preparedMacApp)
        try fileManager.createSymbolicLink(at: preparedMacApp, withDestinationURL: macApp)
    }

    let distributionIOS = archives.appendingPathComponent("Distribution/iOS")
    let distributionMac = archives.appendingPathComponent("Distribution/macOS")
    try fileManager.createDirectory(at: distributionIOS, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: distributionMac, withIntermediateDirectories: true)
    try Data("fixture ipa bytes".utf8).write(to: distributionIOS.appendingPathComponent("KnitNote.ipa"))
    try Data("fixture pkg bytes".utf8).write(to: distributionMac.appendingPathComponent("KnitNote.pkg"))
    for directory in [distributionIOS, distributionMac] {
        try writePlist(
            ["teamID": "9CFPAUL5N5", "signingCertificate": "Apple Distribution"],
            to: directory.appendingPathComponent("DistributionSummary.plist")
        )
        try fileManager.copyItem(
            at: releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/ExportOptions-AppStore.plist"),
            to: directory.appendingPathComponent("ExportOptions.plist")
        )
    }
    if let relative = extraDistributionBeforeProvenance {
        let artifact = archives.appendingPathComponent(relative)
        try fileManager.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture retained artifact".utf8).write(to: artifact)
    }
    if testFixtureSentinelBeforeProvenance {
        try Data().write(to: archives.appendingPathComponent(".TEST_FIXTURE_NOT_FOR_RELEASE"))
    }

    let fakeBin = temporaryRoot.appendingPathComponent("bin")
    try fileManager.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    let codesign = fakeBin.appendingPathComponent("codesign")
    let shouldFailCodesign = codesignFailure ? "yes" : "no"
    let iOSIdentifier = identifierXML(identifierValues(
        for: .iOS, location: .signed, mutation: identifierMutation,
        canonicalOverride: signedIdentifierOverride
    ))
    let watchIdentifier = identifierXML(identifierValues(
        for: .watch, location: .signed, mutation: identifierMutation,
        canonicalOverride: signedIdentifierOverride
    ))
    let shareIdentifier = identifierXML(identifierValues(
        for: .share, location: .signed, mutation: identifierMutation,
        canonicalOverride: signedIdentifierOverride
    ))
    let macIdentifier = identifierXML(identifierValues(
        for: .macOS, location: .signed, mutation: identifierMutation,
        canonicalOverride: signedIdentifierOverride
    ))
    let iOSCloudEntitlements = signedCloudEntitlements(for: .iOS, mutation: signedCloudEntitlementMutation)
    let watchCloudEntitlements = signedCloudEntitlements(for: .watch, mutation: signedCloudEntitlementMutation)
    let shareCloudEntitlements = signedCloudEntitlements(for: .share, mutation: signedCloudEntitlementMutation)
    let macCloudEntitlements = signedCloudEntitlements(for: .macOS, mutation: signedCloudEntitlementMutation)
    let iOSIdentifierAlias = conflictingSignedIdentifierAlias(for: .iOS, mutation: signedCloudEntitlementMutation)
    let watchIdentifierAlias = conflictingSignedIdentifierAlias(for: .watch, mutation: signedCloudEntitlementMutation)
    let shareIdentifierAlias = conflictingSignedIdentifierAlias(for: .share, mutation: signedCloudEntitlementMutation)
    let macIdentifierAlias = conflictingSignedIdentifierAlias(for: .macOS, mutation: signedCloudEntitlementMutation)
    let macSecurityEntitlements = [
        "com.apple.security.app-sandbox",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.network.client",
    ].map { key in
        guard missingMacSignedEntitlement != key else { return "" }
        let value = changedMacSignedEntitlement == key ? "<false/>" : "<true/>"
        return "<key>\(key)</key>\(value)"
    }.joined() + macCloudEntitlements
        + (extraMacSignedEntitlement.map { "<key>\($0)</key><true/>" } ?? "")
    try """
    #!/bin/sh
    case "$*" in
      *.xcarchive*) [ "\(rejectArchiveCodesign ? "yes" : "no")" = "yes" ] && exit 91 ;;
    esac
    if [ "${1:-}" = "--verify" ] && [ "\(shouldFailCodesign)" = "yes" ]; then
      exit 1
    elif [ "${1:-}" = "-dvv" ]; then
      printf '%s\n' 'Authority=Apple Distribution: Fixture (\(signingTeam))' 'TeamIdentifier=\(signingTeam)' >&2
    elif [ "${1:-}" = "-d" ] && [ "${2#--extract-certificates=}" != "${2:-}" ]; then
      prefix="${2#--extract-certificates=}"
      [ -n "$prefix" ] || exit 64
      printf '%s' 'certificate' > "${prefix}0"
    elif [ "${1:-}" = "-d" ] && [ "${2:-}" = "--extract-certificates" ]; then
      exit 64
    elif [ "${1:-}" = "-d" ]; then
      case "${4:-${3:-}}" in
        *KnitNoteWatch.app) identity='\(watchIdentifier)'; group='\(watchCloudEntitlements)\(watchIdentifierAlias)' ;;
        *KnitNoteShare.appex) identity='\(shareIdentifier)'; group='<key>com.apple.security.application-groups</key><array><string>group.com.phillon.KnitNote</string></array>\(shareCloudEntitlements)\(shareIdentifierAlias)' ;;
        *macOS*|*/mac/*) identity='\(macIdentifier)'; group='\(macSecurityEntitlements)\(macIdentifierAlias)' ;;
        *) identity='\(iOSIdentifier)'; group='<key>com.apple.security.application-groups</key><array><string>group.com.phillon.KnitNote</string></array>\(iOSCloudEntitlements)\(iOSIdentifierAlias)' ;;
      esac
      printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'"$identity"'<key>com.apple.developer.team-identifier</key><string>9CFPAUL5N5</string><key>get-task-allow</key><false/>'"$group"'</dict></plist>'
    fi
    exit 0
    """.write(to: codesign, atomically: true, encoding: .utf8)
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: codesign.path
    )
    let security = fakeBin.appendingPathComponent("security")
    try """
    #!/bin/sh
    cat "$4"
    """.write(to: security, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: security.path)
    let git = fakeBin.appendingPathComponent("git")
    try """
    #!/bin/sh
    case "$*" in
      *"rev-parse HEAD"*) printf '%s\n' '\(gitHead)' ;;
      *"status --porcelain"*) \(dirtySource ? "printf '%s\\n' ' M fixture'" : ":") ;;
      *) /usr/bin/git "$@" ;;
    esac
    """.write(to: git, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: git.path)
    let swift = fakeBin.appendingPathComponent("swift")
    try """
    #!/bin/sh
    exit 0
    """.write(to: swift, atomically: true, encoding: .utf8)
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: swift.path
    )
    let extractionLog = temporaryRoot.appendingPathComponent("extraction-paths.log")
    let ditto = fakeBin.appendingPathComponent("ditto")
    try """
    #!/bin/sh
    [ "\(extractionFailure == "iOS" ? "yes" : "no")" = "yes" ] && exit 93
    destination="$4"
    printf '%s\n' "$destination" >> '\(extractionLog.path)'
    mkdir -p "$destination"
    cp -R '\(preparedIOS.path)/.' "$destination/"
    """.write(to: ditto, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: ditto.path)
    let pkgutil = fakeBin.appendingPathComponent("pkgutil")
    try """
    #!/bin/sh
    if [ "${1:-}" = "--check-signature" ]; then
      case "\(packageSignature)" in
        valid) printf '%s\\n' 'Status: signed by a certificate trusted by macOS' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (9CFPAUL5N5)' ' 2. Apple Worldwide Developer Relations Certification Authority' ' 3. Apple Root CA'; exit 0 ;;
        indented-valid) printf '%s\\n' '   Status: signed by a developer certificate issued by Apple (Development)   ' '   Certificate Chain:   ' '    1. 3rd Party Mac Developer Installer: KnitNote (9CFPAUL5N5)   ' '    2. Apple Worldwide Developer Relations Certification Authority   ' '    3. Apple Root CA   '; exit 0 ;;
        developer-issued) printf '%s\\n' 'Status: signed by a developer certificate issued by Apple (Development)' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (9CFPAUL5N5)' ' 2. Apple Worldwide Developer Relations Certification Authority' ' 3. Apple Root CA'; exit 0 ;;
        wrong-team) printf '%s\\n' 'Status: signed by a certificate trusted by macOS' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (BADTEAM123)' ' 2. Apple Worldwide Developer Relations Certification Authority' ' 3. Apple Root CA'; exit 0 ;;
        wrong-prefix) printf '%s\\n' 'Status: signed by a certificate trusted by macOS' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (X9CFPAUL5N5)' ' 2. Apple Worldwide Developer Relations Certification Authority' ' 3. Apple Root CA'; exit 0 ;;
        wrong-suffix) printf '%s\\n' 'Status: signed by a certificate trusted by macOS' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (9CFPAUL5N5X)' ' 2. Apple Worldwide Developer Relations Certification Authority' ' 3. Apple Root CA'; exit 0 ;;
        mixed-team) printf '%s\\n' 'Status: signed by a certificate trusted by macOS' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (BADTEAM123)' ' 2. 3rd Party Mac Developer Installer: Decoy (9CFPAUL5N5)' ' 3. Apple Worldwide Developer Relations Certification Authority' ' 4. Apple Root CA'; exit 0 ;;
        arbitrary-status) printf '%s\\n' 'Status: package signed under an arbitrary policy' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (9CFPAUL5N5)' ' 2. Apple Worldwide Developer Relations Certification Authority' ' 3. Apple Root CA'; exit 0 ;;
        revoked-status) printf '%s\\n' 'Status: certificate has been revoked' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (9CFPAUL5N5)' ' 2. Apple Worldwide Developer Relations Certification Authority' ' 3. Apple Root CA'; exit 0 ;;
        error-status) printf '%s\\n' 'Status: unable to verify certificate' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (9CFPAUL5N5)' ' 2. Apple Worldwide Developer Relations Certification Authority' ' 3. Apple Root CA'; exit 0 ;;
        wrong-chain) printf '%s\\n' 'Status: signed by a certificate trusted by macOS' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (9CFPAUL5N5)' ' 2. Example Worldwide Developer Relations Certification Authority' ' 3. Apple Root CA'; exit 0 ;;
        allowed-plus-revoked) printf '%s\\n' 'Status: signed by a certificate trusted by macOS' 'Status: certificate has been revoked' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (9CFPAUL5N5)' ' 2. Apple Worldwide Developer Relations Certification Authority' ' 3. Apple Root CA'; exit 0 ;;
        wrong-intermediate-decoy) printf '%s\\n' 'Status: signed by a certificate trusted by macOS' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (9CFPAUL5N5)' ' 2. Example Apple Worldwide Developer Relations Certification Authority' ' 3. Apple Root CA'; exit 0 ;;
        repeated-leaf-one) printf '%s\\n' 'Status: signed by a certificate trusted by macOS' 'Certificate Chain:' ' 1. 3rd Party Mac Developer Installer: KnitNote (BADTEAM123)' ' 1. 3rd Party Mac Developer Installer: Decoy (9CFPAUL5N5)' ' 2. Apple Worldwide Developer Relations Certification Authority' ' 3. Apple Root CA'; exit 0 ;;
        unsigned) echo 'Status: no signature' >&2; exit 12 ;;
        tampered) echo 'Status: package signature is invalid' >&2; exit 13 ;;
        untrusted) echo 'Status: signed by a certificate not trusted by macOS' >&2; exit 14 ;;
      esac
    fi
    [ "\(extractionFailure == "macOS" ? "yes" : "no")" = "yes" ] && exit 94
    destination="$3"
    printf '%s\n' "$destination" >> '\(extractionLog.path)'
    [ "\(pkgutilRejectsExistingDestination ? "yes" : "no")" = "yes" ] && [ -e "$destination" ] && exit 95
    mkdir "$destination"
    cp -R '\(preparedMac.path)/.' "$destination/"
    """.write(to: pkgutil, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: pkgutil.path)
    let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    let provenance = archives.appendingPathComponent("provenance.json")
    for archiveName in ["KnitNote-iOS-Privacy.xcarchive", "KnitNote-macOS-Privacy.xcarchive"] {
        try writePlist(["Fixture": true], to: archives.appendingPathComponent("\(archiveName)/Info.plist"))
    }
    let manifest = Process()
    manifest.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    manifest.arguments = [
        "python3", releaseAuditRepositoryRoot.appendingPathComponent("AppStore/Verification/release_archive_manifest.py").path,
        "create", "--archives", archives.path, "--source-commit", fixtureCommit, "--output", provenance.path,
    ]
    try manifest.run()
    manifest.waitUntilExit()
    guard manifest.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    if provenancePathOverride != nil {
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: provenance)) as? [String: Any])
        payload["sourceCommit"] = String(repeating: "b", count: 40)
        try JSONSerialization.data(withJSONObject: payload).write(to: provenance)
    }
    if mutateAfterProvenance {
        try Data("mutated".utf8).write(to: artifacts[0].1)
    }
    if let relative = mutateDistributionAfterProvenance {
        try Data("mutated distribution artifact".utf8).write(
            to: archives.appendingPathComponent(relative)
        )
    }
    if let relative = removeDistributionAfterProvenance {
        try fileManager.removeItem(at: archives.appendingPathComponent(relative))
    }
    if let relative = symlinkDistributionAfterProvenance {
        let artifact = archives.appendingPathComponent(relative)
        try fileManager.removeItem(at: artifact)
        try fileManager.createSymbolicLink(
            at: artifact,
            withDestinationURL: archives.appendingPathComponent("Distribution/iOS/ExportOptions.plist")
        )
    }
    if symlinkDistributionParentAfterProvenance {
        let distribution = archives.appendingPathComponent("Distribution")
        let original = distribution.appendingPathComponent("iOS")
        let real = distribution.appendingPathComponent("iOS-real")
        try fileManager.moveItem(at: original, to: real)
        try fileManager.createSymbolicLink(atPath: original.path, withDestinationPath: "iOS-real")
    }
    return ArchiveFixture(
        temporaryRoot: temporaryRoot,
        archives: archives,
        macPackageApp: preparedMacApp,
        commandPath: "\(fakeBin.path):\(existingPath)",
        provenance: provenance,
        extractionLog: extractionLog
    )
}

private func compiledInfoPlistValues(locale: String) throws -> [String: String] {
    let url = releaseAuditRepositoryRoot
        .appendingPathComponent("KnitNote/Localization/InfoPlist.xcstrings")
    let payload = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    let strings = try #require(payload["strings"] as? [String: Any])
    return try Dictionary(uniqueKeysWithValues: strings.map { key, rawEntry in
        let entry = try #require(rawEntry as? [String: Any])
        let localizations = entry["localizations"] as? [String: Any] ?? [:]
        if let localization = localizations[locale] as? [String: Any],
           let unit = localization["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            return (key, value)
        }
        #expect(locale == "en")
        return (key, key)
    })
}

private func writePlist(_ value: Any, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try PropertyListSerialization.data(
        fromPropertyList: value,
        format: .xml,
        options: 0
    )
    try data.write(to: url)
}

private func writeUTF16LEStrings(_ values: [String: String], to url: URL) throws {
    let xml = try PropertyListSerialization.data(
        fromPropertyList: values,
        format: .xml,
        options: 0
    )
    // This matches the archived macOS table shape: UTF-16LE bytes while the
    // XML declaration still says UTF-8. Apple plutil accepts it; plistlib does not.
    let text = try #require(String(data: xml, encoding: .utf8))
    var data = Data([0xff, 0xfe])
    data.append(try #require(text.data(using: .utf16LittleEndian)))
    try data.write(to: url)
}

private let releaseAuditRepositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
