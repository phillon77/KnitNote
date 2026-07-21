import Foundation

public struct PreparedWatchCommand: Codable, Equatable, Sendable {
    public let command: WatchCounterCommand
    public let expectedCounterRevision: UInt64
    public let expectedCounterValue: Int?

    public init(
        command: WatchCounterCommand,
        expectedCounterRevision: UInt64,
        expectedCounterValue: Int? = nil
    ) {
        self.command = command
        self.expectedCounterRevision = expectedCounterRevision
        self.expectedCounterValue = expectedCounterValue
    }
}

public enum WatchCommandRecoveryState: Equatable, Sendable {
    case ready
    case requiresFreshHandshake
}

public enum WatchCommandPersistenceError: Error, Equatable, Sendable {
    case requiresFreshHandshake
}

public enum WatchCommandPersistenceBoundary: CaseIterable, Equatable, Sendable {
    case afterPreparedCommandSave
    case afterProjectArchiveSave
    case afterLedgerSave
    case afterPreparedCommandDeletion
}

@MainActor extension JSONProjectStore {
    public func recoverWatchCommandPersistence(
        ledgerURL: URL,
        preparedCommandURL: URL,
        now: Date = .now
    ) throws -> WatchCommandRecoveryState {
        let ledgerFile = AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
        var ledger = try loadLedgerRecoveringCorruption(from: ledgerFile)

        let preparedFile = AtomicWatchSyncFile<PreparedWatchCommand>(url: preparedCommandURL)
        let prepared: PreparedWatchCommand?
        do {
            prepared = try preparedFile.load()
        } catch {
            try preparedFile.quarantineCorruptFile()
            try requireFreshHandshake(ledger: &ledger, file: ledgerFile)
            return .requiresFreshHandshake
        }
        if ledger.requiresFreshHandshake { return .requiresFreshHandshake }
        guard let prepared else { return .ready }

        if ledger.contains(prepared.command.id) {
            try removePreparedCommand(at: preparedCommandURL)
            return .ready
        }
        guard
            let project = project(id: prepared.command.projectID),
            !project.isCompleted,
            let counter = project.counters.first(where: { $0.id == prepared.command.counterID })
        else {
            try requireFreshHandshake(ledger: &ledger, file: ledgerFile)
            return .requiresFreshHandshake
        }

        if counter.mutationRevision == prepared.expectedCounterRevision {
            if let expectedValue = prepared.expectedCounterValue {
                guard counter.value == expectedValue else {
                    try requireFreshHandshake(ledger: &ledger, file: ledgerFile)
                    return .requiresFreshHandshake
                }
                if prepared.isAcceptedNoOp {
                    ledger.record(prepared.command.id, at: now)
                } else {
                    _ = try applyWatchCommand(prepared.command, ledger: &ledger, now: now)
                }
            } else {
                _ = try applyWatchCommand(prepared.command, ledger: &ledger, now: now)
            }
        } else if
            prepared.expectedCounterRevision != UInt64.max,
            counter.mutationRevision == prepared.expectedCounterRevision + 1
        {
            ledger.record(prepared.command.id, at: now)
        } else {
            try requireFreshHandshake(ledger: &ledger, file: ledgerFile)
            return .requiresFreshHandshake
        }

        try ledgerFile.save(ledger)
        try removePreparedCommand(at: preparedCommandURL)
        return .ready
    }

    public func applyWatchCommandDurably(
        _ command: WatchCounterCommand,
        ledgerURL: URL,
        preparedCommandURL: URL,
        now: Date = .now,
        failureInjector: (WatchCommandPersistenceBoundary) throws -> Void = { _ in }
    ) throws -> WatchCommandAcknowledgement {
        guard try recoverWatchCommandPersistence(
            ledgerURL: ledgerURL,
            preparedCommandURL: preparedCommandURL,
            now: now
        ) == .ready else {
            throw WatchCommandPersistenceError.requiresFreshHandshake
        }

        let ledgerFile = AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
        var ledger = try loadLedgerRecoveringCorruption(from: ledgerFile)
        guard !ledger.requiresFreshHandshake else {
            throw WatchCommandPersistenceError.requiresFreshHandshake
        }
        if ledger.contains(command.id) {
            return try applyWatchCommand(command, ledger: &ledger, now: now)
        }

        guard
            command.schemaVersion == WatchCounterCommand.currentSchemaVersion,
            let project = project(id: command.projectID),
            !project.isCompleted,
            let counter = project.counters.first(where: { $0.id == command.counterID })
        else {
            let acknowledgement = try applyWatchCommand(command, ledger: &ledger, now: now)
            try ledgerFile.save(ledger)
            return acknowledgement
        }

        let preparedFile = AtomicWatchSyncFile<PreparedWatchCommand>(url: preparedCommandURL)
        try preparedFile.save(PreparedWatchCommand(
            command: command,
            expectedCounterRevision: counter.mutationRevision,
            expectedCounterValue: counter.value
        ))
        try failureInjector(.afterPreparedCommandSave)

        let acknowledgement = try applyWatchCommand(command, ledger: &ledger, now: now)
        try failureInjector(.afterProjectArchiveSave)
        try ledgerFile.save(ledger)
        try failureInjector(.afterLedgerSave)
        try removePreparedCommand(at: preparedCommandURL)
        try failureInjector(.afterPreparedCommandDeletion)
        return acknowledgement
    }

    public func completeWatchQueueHandshake(
        queuedCommandIDs: [UUID],
        ledgerURL: URL,
        now: Date = .now
    ) throws {
        let ledgerFile = AtomicWatchSyncFile<ProcessedWatchCommandLedger>(url: ledgerURL)
        var ledger = try loadLedgerRecoveringCorruption(from: ledgerFile)
        for id in queuedCommandIDs where !ledger.contains(id) {
            ledger.record(id, at: now)
        }
        if ledger.requiresFreshHandshake {
            ledger.markHandshakeComplete()
        }
        try ledgerFile.save(ledger)
    }

    private func loadLedgerRecoveringCorruption(
        from file: AtomicWatchSyncFile<ProcessedWatchCommandLedger>
    ) throws -> ProcessedWatchCommandLedger {
        do {
            return try file.load() ?? ProcessedWatchCommandLedger()
        } catch {
            try file.quarantineCorruptFile()
            let ledger = ProcessedWatchCommandLedger(requiresFreshHandshake: true)
            try file.save(ledger)
            return ledger
        }
    }

    private func requireFreshHandshake(
        ledger: inout ProcessedWatchCommandLedger,
        file: AtomicWatchSyncFile<ProcessedWatchCommandLedger>
    ) throws {
        ledger.markRequiresFreshHandshake()
        try file.save(ledger)
    }

    private func removePreparedCommand(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

private extension PreparedWatchCommand {
    var isAcceptedNoOp: Bool {
        guard let expectedCounterValue else { return false }
        return switch command.operation {
        case .increment:
            expectedCounterValue == Int.max
        case .decrement, .reset:
            expectedCounterValue == 0
        }
    }
}
