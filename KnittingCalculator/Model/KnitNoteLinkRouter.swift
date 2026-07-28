import Foundation

enum KnitNoteLinkDestination: Equatable {
    case finished
    case openStore(URL)
}

enum KnitNoteLinkRouter {
    static let launchURL = URL(string: "knitnote://")!
    static let storeURL = URL(string: "https://apps.apple.com/app/id6793023054")!

    static func destination(after opened: Bool) -> KnitNoteLinkDestination {
        opened ? .finished : .openStore(storeURL)
    }
}
