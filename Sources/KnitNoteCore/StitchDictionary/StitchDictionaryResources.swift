import Foundation

/// Core is compiled both as a Swift package and directly into the application.
/// Callers retain their own domain errors for a missing resource.
enum StitchDictionaryResources {
    static func url(named name: String, bundle: Bundle? = nil) -> URL? {
        let resourceBundle: Bundle
        if let bundle {
            resourceBundle = bundle
        } else {
            #if SWIFT_PACKAGE
            resourceBundle = .module
            #else
            resourceBundle = .main
            #endif
        }
        return resourceBundle.url(forResource: name, withExtension: "json")
    }
}
