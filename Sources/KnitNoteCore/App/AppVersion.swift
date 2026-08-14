public struct AppVersion: Comparable, Hashable, Sendable, Codable {
    public let major: UInt
    public let minor: UInt
    public let patch: UInt

    public init?(_ rawValue: String) {
        let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3 else { return nil }

        guard
            let major = Self.parse(components[0]),
            let minor = Self.parse(components[1]),
            let patch = components.count == 3 ? Self.parse(components[2]) : 0
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var displayString: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    private static func parse(_ component: Substring) -> UInt? {
        guard !component.isEmpty, component.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return UInt(component)
    }
}
