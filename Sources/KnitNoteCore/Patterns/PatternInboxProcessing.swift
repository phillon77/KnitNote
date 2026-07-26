import Foundation

public protocol PatternInboxProcessing: Sendable {
    func pendingItems() async throws -> [PatternInboxItem]
    func process(
        itemID: UUID,
        resolution: PatternImportDuplicateResolution
    ) async throws -> PatternImportOutcome
    func discard(itemID: UUID) async throws
}

public enum PatternInboxDriverBlock: Equatable, Sendable {
    case selection(item: PatternInboxItem, candidatePatternIDs: [UUID])
    case failure(itemID: UUID?)
}

public struct PatternInboxDriverUpdate: Equatable, Sendable {
    public let imported: [PatternImportOutcome]
    public let blocking: PatternInboxDriverBlock?
    public let isBusy: Bool

    public init(
        imported: [PatternImportOutcome] = [],
        blocking: PatternInboxDriverBlock? = nil,
        isBusy: Bool = false
    ) {
        self.imported = imported
        self.blocking = blocking
        self.isBusy = isBusy
    }

    public static let busy = PatternInboxDriverUpdate(isBusy: true)
}

public actor PatternInboxDriver {
    private let processing: any PatternInboxProcessing
    private var isRunning = false

    public init(processing: any PatternInboxProcessing) {
        self.processing = processing
    }

    public func processPending() async throws -> PatternInboxDriverUpdate {
        guard !isRunning else { return .busy }
        isRunning = true
        defer { isRunning = false }
        return try await processRemaining()
    }

    public func resolve(
        itemID: UUID,
        resolution: PatternImportDuplicateResolution
    ) async throws -> PatternInboxDriverUpdate {
        guard !isRunning else { return .busy }
        isRunning = true
        defer { isRunning = false }

        do {
            let outcome = try await processing.process(itemID: itemID, resolution: resolution)
            if case let .needsSelection(_, candidatePatternIDs) = outcome {
                let item = try await processing.pendingItems().first { $0.id == itemID }
                guard let item else {
                    return PatternInboxDriverUpdate(blocking: .failure(itemID: itemID))
                }
                return PatternInboxDriverUpdate(
                    blocking: .selection(item: item, candidatePatternIDs: candidatePatternIDs)
                )
            }
            return try await processRemaining(imported: [outcome])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return PatternInboxDriverUpdate(blocking: .failure(itemID: itemID))
        }
    }

    public func discard(itemID: UUID) async throws -> PatternInboxDriverUpdate {
        guard !isRunning else { return .busy }
        isRunning = true
        defer { isRunning = false }

        do {
            try await processing.discard(itemID: itemID)
            return try await processRemaining()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return PatternInboxDriverUpdate(blocking: .failure(itemID: itemID))
        }
    }

    private func processRemaining(
        imported initialImported: [PatternImportOutcome] = []
    ) async throws -> PatternInboxDriverUpdate {
        var imported = initialImported
        let items: [PatternInboxItem]
        do {
            items = try await processing.pendingItems()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return PatternInboxDriverUpdate(imported: imported, blocking: .failure(itemID: nil))
        }

        for item in items {
            do {
                try Task.checkCancellation()
                let outcome = try await processing.process(
                    itemID: item.id,
                    resolution: .automatic
                )
                switch outcome {
                case .created, .existing:
                    imported.append(outcome)
                case let .needsSelection(_, candidatePatternIDs):
                    return PatternInboxDriverUpdate(
                        imported: imported,
                        blocking: .selection(
                            item: item,
                            candidatePatternIDs: candidatePatternIDs
                        )
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return PatternInboxDriverUpdate(
                    imported: imported,
                    blocking: .failure(itemID: item.id)
                )
            }
        }
        return PatternInboxDriverUpdate(imported: imported)
    }
}
