import Foundation

enum CreateProjectFailurePresentation: Equatable {
    case requestUnlock
    case saveError(String)
}

struct CreateProjectFailureMapper {
    static func presentation(for error: Error) -> CreateProjectFailurePresentation {
        if let storeError = error as? ProjectStoreError,
           storeError == .accessRestricted {
            return .requestUnlock
        }
        return .saveError(error.localizedDescription)
    }
}
