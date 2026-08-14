import Foundation

enum LaunchServicesTestGate {
    private static let gate = AsyncSerializedGate()

    static func withSerializedAccess<Result>(
        _ operation: @Sendable () throws -> Result
    ) async rethrows -> Result where Result: Sendable {
        try await gate.perform(operation)
    }
}

private actor AsyncSerializedGate {
    func perform<Result>(
        _ operation: @Sendable () throws -> Result
    ) rethrows -> Result where Result: Sendable {
        try operation()
    }
}
