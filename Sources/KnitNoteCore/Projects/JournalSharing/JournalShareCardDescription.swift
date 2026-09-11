import Foundation

public enum JournalShareFormat: String, CaseIterable, Sendable {
    case post, story

    public var pixelWidth: Int { 1_080 }
    public var pixelHeight: Int { self == .post ? 1_350 : 1_920 }
}

public struct JournalShareVisibility: Equatable, Sendable {
    public var showsProjectName = true
    public var showsDate = true
    public var showsCaption = true
    public var showsBrand = true

    public init(
        showsProjectName: Bool = true,
        showsDate: Bool = true,
        showsCaption: Bool = true,
        showsBrand: Bool = true
    ) {
        self.showsProjectName = showsProjectName
        self.showsDate = showsDate
        self.showsCaption = showsCaption
        self.showsBrand = showsBrand
    }
}

public struct JournalShareCardDescription: Equatable, Sendable {
    public let format: JournalShareFormat
    public let projectName: String?
    public let formattedDate: String?
    public let caption: String?
    public let showsBrand: Bool

    public static func make(
        format: JournalShareFormat,
        visibility: JournalShareVisibility,
        projectName: String,
        createdAt: Date,
        caption: String?,
        locale: Locale
    ) -> Self {
        Self(
            format: format,
            projectName: visibility.showsProjectName ? projectName : nil,
            formattedDate: visibility.showsDate
                ? createdAt.formatted(.dateTime.year().month().day().locale(locale))
                : nil,
            caption: visibility.showsCaption ? caption : nil,
            showsBrand: visibility.showsBrand
        )
    }
}
