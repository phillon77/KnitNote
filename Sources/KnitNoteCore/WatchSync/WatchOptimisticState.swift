import Foundation

public struct WatchOptimisticState: Equatable, Sendable {
    private var authoritativeSnapshot: WatchSyncSnapshot?
    public private(set) var pendingCommands: [WatchCounterCommand]
    public private(set) var selectedProjectID: UUID?
    public private(set) var selectedCounterID: UUID?

    public init(cache: WatchSyncCache) {
        authoritativeSnapshot = cache.snapshot
        pendingCommands = cache.pendingCommands
        selectedProjectID = cache.selectedProjectID
        selectedCounterID = cache.selectedCounterID
        repairSelection()
    }

    public var snapshot: WatchSyncSnapshot? {
        pendingCommands.reduce(authoritativeSnapshot) { current, command in
            guard let current else { return nil }
            return Self.applying(command, to: current)
        }
    }

    public var cache: WatchSyncCache {
        WatchSyncCache(
            snapshot: authoritativeSnapshot,
            pendingCommands: pendingCommands,
            selectedProjectID: selectedProjectID,
            selectedCounterID: selectedCounterID
        )
    }

    @discardableResult
    public mutating func makeAndEnqueue(
        projectID: UUID,
        counterID: UUID,
        operation: WatchCounterOperation,
        id: UUID = UUID(),
        createdAt: Date = .now
    ) -> WatchCounterCommand {
        let command = WatchCounterCommand(
            id: id,
            projectID: projectID,
            counterID: counterID,
            operation: operation,
            createdAt: createdAt
        )
        _ = enqueue(command)
        return command
    }

    @discardableResult
    public mutating func enqueue(_ command: WatchCounterCommand) -> WatchCommandRejection? {
        guard command.schemaVersion == WatchCounterCommand.currentSchemaVersion else {
            return .unsupportedSchema
        }
        guard let project = authoritativeSnapshot?.projects.first(where: {
            $0.id == command.projectID
        }) else {
            return .projectMissing
        }
        guard !project.isCompleted else { return .projectCompleted }
        guard project.counters.contains(where: { $0.id == command.counterID }) else {
            return .counterMissing
        }
        guard !pendingCommands.contains(where: { $0.id == command.id }) else { return nil }

        pendingCommands.append(command)
        return nil
    }

    @discardableResult
    public mutating func acknowledge(_ acknowledgement: WatchCommandAcknowledgement) -> Bool {
        guard let index = pendingCommands.firstIndex(where: {
            $0.id == acknowledgement.commandID
        }) else {
            return false
        }

        pendingCommands.remove(at: index)
        authoritativeSnapshot = acknowledgement.snapshot
        repairSelection()
        return true
    }

    public mutating func replaceSnapshot(_ snapshot: WatchSyncSnapshot) {
        authoritativeSnapshot = snapshot
        repairSelection()
    }

    @discardableResult
    public mutating func selectProject(_ projectID: UUID?) -> Bool {
        guard let projectID else {
            repairSelection()
            return true
        }
        guard let project = authoritativeSnapshot?.projects.first(where: { $0.id == projectID }) else {
            return false
        }
        selectedProjectID = project.id
        selectedCounterID = project.selectedCounterID
        return true
    }

    @discardableResult
    public mutating func selectCounter(_ counterID: UUID?) -> Bool {
        guard let projectID = selectedProjectID,
              let project = authoritativeSnapshot?.projects.first(where: { $0.id == projectID })
        else {
            return false
        }
        guard let counterID else {
            selectedCounterID = project.selectedCounterID
            return true
        }
        guard project.counters.contains(where: { $0.id == counterID }) else { return false }
        selectedCounterID = counterID
        return true
    }

    public func displayedValue(projectID: UUID, counterID: UUID) -> Int? {
        snapshot?.projects
            .first(where: { $0.id == projectID })?.counters
            .first(where: { $0.id == counterID })?.value
    }

    private mutating func repairSelection() {
        let validated = WatchSyncCache(
            snapshot: authoritativeSnapshot,
            pendingCommands: pendingCommands,
            selectedProjectID: selectedProjectID,
            selectedCounterID: selectedCounterID
        )
        selectedProjectID = validated.selectedProjectID
        selectedCounterID = validated.selectedCounterID
    }

    private static func applying(
        _ command: WatchCounterCommand,
        to snapshot: WatchSyncSnapshot
    ) -> WatchSyncSnapshot {
        let projects = snapshot.projects.map { project in
            guard project.id == command.projectID,
                  !project.isCompleted,
                  project.counters.contains(where: { $0.id == command.counterID })
            else {
                return project
            }

            let counters = project.counters.map { counter in
                guard counter.id == command.counterID else { return counter }
                let value = switch command.operation {
                case .increment:
                    counter.value == Int.max ? Int.max : counter.value + 1
                case .decrement:
                    max(0, counter.value - 1)
                case .reset:
                    0
                }
                return WatchCounterSnapshot(id: counter.id, name: counter.name, value: value)
            }

            return (try? WatchProjectSnapshot(
                id: project.id,
                name: project.name,
                isCompleted: project.isCompleted,
                updatedAt: project.updatedAt,
                counters: counters,
                selectedCounterID: project.selectedCounterID
            )) ?? project
        }

        return WatchSyncSnapshot(
            schemaVersion: snapshot.schemaVersion,
            generatedAt: snapshot.generatedAt,
            projects: projects
        )
    }
}
