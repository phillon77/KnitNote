import SwiftUI

extension PatternLibrarySort {
    var localizationKey: LocalizedStringKey {
        switch self {
        case .recentlyAdded: "patterns.library.sort.recent"
        case .name: "patterns.library.sort.name"
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyAdded: "clock"
        case .name: "textformat"
        }
    }
}
