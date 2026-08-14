import Foundation

actor LaunchServicesTestGate {
    static let shared = LaunchServicesTestGate()

    func withLock<Result>(
        _ operation: @Sendable () throws -> Result
    ) rethrows -> Result where Result: Sendable {
        try operation()
    }
}
