import CloudKit
import Combine
import Foundation
import Testing
@testable import KnitNote

@MainActor @Suite struct ConflictRebaseIntegrationTests {
    @Test(arguments: [false, true])
    func resolverThrowAfterAwaitCannotMaintainJournalOrBlockStaleEpoch(invalidate: Bool) async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        let gate = ConflictContinuationGate()
        let adapter = JSONProjectStoreRemoteBatchCommitter(store: h.f.store, expectedAccount: h.f.account,
            attachmentSources: { _ in try await gate.suspend(); throw ConflictContinuationFault.injected },
            verifyAcknowledgement: { _ in })
        let committer = ConflictCommitProbe(adapter)
        let io = SyncJournalIOCounters()
        let observedJournal = FileSyncMutationJournal(url: h.f.journal.recoveryLocation, counters: io)
        let coordinator = h.coordinator(committer: committer, journal: observedJournal)
        var issues: [CloudSyncIssue] = []
        let observation = coordinator.$status.sink { if let issue = $0.issue { issues.append(issue) } }
        defer { observation.cancel() }
        await coordinator.start(); await h.transport.receiveZoneReady(h.f.zone)
        let outgoing = try await h.outgoing()
        await h.transport.receiveFailedSave(outgoing, error: h.conflict())
        await until { gate.isSuspended }
        let epoch = try #require(committer.firstAttempt?.epoch)
        let residue = try ConflictCleanupResidue(h.f)
        let frozen = try residue.snapshot()
        let metadataReads = io.metadataReadCount
        if invalidate { epoch.invalidate() }
        gate.resume()
        if !invalidate {
            await until { issues.contains(.durableCommit) }
            #expect(coordinator.status.pendingCount == 1)
        }
        await finishContinuation(coordinator, transport: h.transport)
        #expect(issues.contains(.durableCommit) == !invalidate)
        #expect(!issues.contains(.journal) && !issues.contains(.operation))
        #expect(try residue.snapshot() == frozen)
        #expect(io.metadataReadCount == metadataReads)
        #expect(FileManager.default.fileExists(atPath: residue.staged.path))
        #expect(h.f.store.project(id: h.f.projectID)?.name == "Local")
    }

    @Test(arguments: ["stale-success", "stale-error", "current-error"])
    func cleanupContinuationCannotMaintainJournalAfterInvalidation(mode: String) async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        let gate = ConflictContinuationGate()
        let probe = ConflictTransportProbe(h.transport)
        var epoch: CloudSyncAccountEpoch?
        probe.afterVerification = { epoch = $0 }
        probe.afterCleanup = {
            try await gate.suspend()
            if mode != "stale-success" { throw ConflictContinuationFault.injected }
        }
        let io = SyncJournalIOCounters()
        let observedJournal = FileSyncMutationJournal(url: h.f.journal.recoveryLocation, counters: io)
        let coordinator = h.coordinator(transport: probe, journal: observedJournal)
        var issues: [CloudSyncIssue] = []
        let observation = coordinator.$status.sink { if let issue = $0.issue { issues.append(issue) } }
        defer { observation.cancel() }
        await coordinator.start(); await h.transport.receiveZoneReady(h.f.zone)
        let outgoing = try await h.outgoing()
        await h.transport.receiveSentChanges(savedRecords: [outgoing], deletedRecordIDs: [])
        await until { gate.isSuspended }
        // The real exact journal ACK and real transport cleanup already ran.
        #expect(try h.f.journal.pendingVersioned().isEmpty)
        let residue = try ConflictCleanupResidue(h.f)
        let frozen = try residue.snapshot()
        let metadataReads = io.metadataReadCount
        if mode != "current-error" { try #require(epoch).invalidate() }
        gate.resume()
        if mode == "current-error" {
            await until { issues.contains(.assetCleanup) }
            #expect(coordinator.status.pendingCount == 0)
        }
        await finishContinuation(coordinator, transport: h.transport)
        #expect(issues.contains(.assetCleanup) == (mode == "current-error"))
        #expect(!issues.contains(.journal) && !issues.contains(.durableCommit))
        #expect(try residue.snapshot() == frozen)
        #expect(io.metadataReadCount == metadataReads)
        #expect(FileManager.default.fileExists(atPath: residue.staged.path))
    }

    @Test(arguments: [false, true])
    func handoffThrowAfterAwaitCannotMaintainJournalOrBlockStaleEpoch(invalidate: Bool) async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        let gate = ConflictContinuationGate()
        let committer = ConflictCommitProbe(h.adapter)
        let probe = ConflictTransportProbe(h.transport)
        probe.afterHandoff = { try await gate.suspend(); throw ConflictContinuationFault.injected }
        let io = SyncJournalIOCounters()
        let observedJournal = FileSyncMutationJournal(url: h.f.journal.recoveryLocation, counters: io)
        let coordinator = h.coordinator(transport: probe, committer: committer, journal: observedJournal)
        var issues: [CloudSyncIssue] = []
        let observation = coordinator.$status.sink { if let issue = $0.issue { issues.append(issue) } }
        defer { observation.cancel() }
        await coordinator.start(); await h.transport.receiveZoneReady(h.f.zone)
        let outgoing = try await h.outgoing()
        await h.transport.receiveFailedSave(outgoing, error: h.conflict())
        await until { gate.isSuspended }
        #expect(h.f.store.project(id: h.f.projectID)?.name == "Remote")
        let residue = try ConflictCleanupResidue(h.f)
        let frozen = try residue.snapshot()
        let metadataReads = io.metadataReadCount
        if invalidate { try #require(committer.firstAttempt?.epoch).invalidate() }
        gate.resume()
        if !invalidate {
            await until { issues.contains(.operation) }
            #expect(coordinator.status.pendingCount == 1)
        }
        await finishContinuation(coordinator, transport: h.transport)
        #expect(issues.contains(.operation) == !invalidate)
        #expect(!issues.contains(.durableCommit) && !issues.contains(.journal))
        #expect(try residue.snapshot() == frozen)
        #expect(io.metadataReadCount == metadataReads)
        #expect(FileManager.default.fileExists(atPath: residue.staged.path))
    }

    // A real queued lifecycle event is handled only after the suspended event's
    // continuation. This observes completion without sleeping to infer absence.
    private func finishContinuation(_ coordinator: KnitNoteCloudSyncCoordinator,
        transport: CKSyncEngineTransport) async {
        var finished = false
        coordinator.accountChangeHandler = { _, _ in finished = true }
        await transport.receiveAccountChange(previous: "adapter-user", current: "sentinel-account")
        await until { finished }
    }

    @Test func committedResultAfterInvalidationCannotReadJournalOrReachHandoff() async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        let io = SyncJournalIOCounters()
        let observedJournal = FileSyncMutationJournal(url: h.f.journal.recoveryLocation, counters: io)
        let committer = ConflictCommitProbe(h.adapter)
        let probe = ConflictTransportProbe(h.transport)
        let coordinator = h.coordinator(transport: probe, committer: committer, journal: observedJournal)
        var residue: ConflictCleanupResidue?
        var frozen: [String: Data] = [:]
        var metadataReads = 0
        committer.afterFirstCommit = {
            residue = try ConflictCleanupResidue(h.f)
            frozen = try #require(residue).snapshot()
            metadataReads = io.metadataReadCount
            try #require(committer.firstAttempt?.epoch).invalidate()
        }
        await coordinator.start(); await h.transport.receiveZoneReady(h.f.zone)
        let outgoing = try await h.outgoing()
        await h.transport.receiveFailedSave(outgoing, error: h.conflict())
        await until { residue != nil }
        await finishContinuation(coordinator, transport: h.transport)
        #expect(h.f.store.project(id: h.f.projectID)?.name == "Remote")
        #expect(probe.handoffs == 0)
        #expect(io.metadataReadCount == metadataReads)
        #expect(try #require(residue).snapshot() == frozen)
    }

    // Catches identity-only ACK, lost later edits, a reset retry budget, or
    // unrelated FIFO/media mutation across a real Core/transport handoff retry.
    @Test func combinedConflictHandoffEditRetryAndExactACKs() async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        let other = try #require(h.f.store.projects.first { $0.id != h.f.projectID })
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        try h.f.store.updateProject(id: other.id, name: "Other pending", toolType: nil,
            toolSize: nil, toolNotes: nil, photoChange: .replace(png))
        let before = try h.f.journal.pendingVersioned()
        let id = SyncEntityID(kind: .project, uuid: h.f.projectID)
        let issued = try #require(before.first { $0.mutation.recordID == id })
        let unrelated = before.filter { $0.mutation.recordID != id }
        #expect(unrelated.count >= 2)
        let canonical = try #require(try h.f.checkpoints.load())
        let live = h.f.root.appendingPathComponent("Live")
        let evidenceFile = SyncAttachmentPublicationEvidenceFile(url: live.appendingPathComponent("SyncMetadata/attachment-versions.json"))
        let evidence = try evidenceFile.load()
        let photoURL = live.appendingPathComponent("ProjectPhotos").appendingPathComponent(
            try #require(h.f.store.project(id: other.id)?.photoFilename))
        let photo = try SyncRegularFileReader().read(photoURL, maximumBytes: 100_000_000)
        let staged = try unrelated.compactMap { item -> (URL, SyncRegularFileRead)? in
            guard let source = item.mutation.attachmentSource else { return nil }
            return (source.fileURL, try SyncRegularFileReader().read(source.fileURL, maximumBytes: 100_000_000))
        }
        var remote = try CloudRecordCodec().decode(h.server)
        remote.entityRevision = max(remote.entityRevision, try #require(issued.mutation.savedRecordVersion).record.entityRevision)
        let replacement = try SyncMutation.save(recordVersion: .init(record: remote), mutationID: issued.mutation.mutationID)
        let firstExpected = try before.map { $0.mutation.recordID == id
            ? try SyncVersionedMutation(mutation: replacement, journalRevision: 1) : $0 }
        var finalExpected: [SyncVersionedMutation] = []
        let committer = ConflictCommitProbe(h.adapter, staleCount: 1)
        let probe = ConflictTransportProbe(h.transport, staleCount: 1)
        probe.beforeFirstStaleHandoff = {
            #expect(try h.f.journal.pendingVersioned() == firstExpected)
            #expect(h.f.store.project(id: h.f.projectID)?.name == "Remote")
            #expect(try h.f.checkpoints.load()?.records == canonical.records.map { $0.id == id ? remote : $0 })
            #expect(try SyncPublicationTransactionFile(archiveURL: h.f.archiveURL).load() == nil)
            try h.rename("Later local edit")
            let appended = try h.f.journal.pendingVersioned()
            let later = try #require(appended.last)
            #expect(appended == firstExpected + [later])
            #expect(later.token.journalRevision == 0)
            #expect(later.mutation.savedRecordVersion?.record.payload.fields["name"]?.value == .string("Later local edit"))
            #expect((later.mutation.savedRecordVersion?.record.payload.fields["name"]?.stamp.logicalRevision ?? 0) > 1000)
            // Capture the actual local immutable save before the retry callback;
            // its causally newer fields must remain byte-for-byte unchanged.
            finalExpected = try appended.map { item in
                try .init(mutation: item.mutation, journalRevision: item.token.journalRevision
                    + (item.mutation.recordID == id ? 1 : 0))
            }
            try await h.transport.schedule(appended)
        }
        let coordinator = h.coordinator(transport: probe, committer: committer)
        await coordinator.start(); await h.transport.receiveZoneReady(h.f.zone)
        let oldSent = try await h.outgoing()
        #expect(try h.f.journal.pendingVersioned() == before)
        await h.transport.receiveFailedSave(oldSent, error: h.conflict())
        await until { probe.accepted == 1 }
        #expect(committer.calls == 3 && probe.handoffs == 2)
        #expect(!finalExpected.isEmpty)
        #expect(try h.f.journal.pendingVersioned() == finalExpected)
        #expect(finalExpected.filter { $0.mutation.recordID == id }.map { $0.token.journalRevision } == [2, 1])
        #expect(h.f.store.project(id: h.f.projectID)?.name == "Later local edit")
        let afterRetryCanonical = try h.f.checkpoints.load()
        let newSent = try await h.outgoing()
        #expect(try CloudRecordCodec().decode(newSent) == remote)
        #expect(oldSent["syncAttemptID"] as? String != newSent["syncAttemptID"] as? String)
        await h.transport.receiveSentChanges(savedRecords: [oldSent], deletedRecordIDs: [])
        // The transport rejects this late callback before emitting .sent. This
        // direct verifier control proves the original authority is stale; it
        // does not claim the coordinator consumed a queued old .sent event.
        let oldAuthority = try #require(committer.firstAttempt)
        #expect(oldAuthority.token == issued.token)
        #expect(oldSent["syncAttemptID"] as? String == oldAuthority.id.uuidString.lowercased())
        await #expect(throws: CloudSyncTransportError.staleOperation) {
            try await h.transport.verifySentMutation(oldAuthority.token,
                attemptID: oldAuthority.id, accountEpoch: oldAuthority.epoch)
        }
        #expect(try h.f.journal.pendingVersioned() == finalExpected)
        #expect(probe.cleanups == 0 && coordinator.status.lastCompleteSuccess == nil)
        let firstCurrent = try #require(finalExpected.first { $0.mutation.recordID == id })
        let afterFirstACK = finalExpected.filter { $0.mutation.identity != firstCurrent.mutation.identity }
        await h.transport.receiveSentChanges(savedRecords: [newSent], deletedRecordIDs: [])
        await until { probe.cleanups == 1 }
        #expect(try h.f.journal.pendingVersioned() == afterFirstACK)
        #expect(try h.f.journal.acknowledgeCurrentVersion(firstCurrent.token) == .alreadyAcknowledged)
        #expect(try h.f.journal.acknowledgeCurrentVersion(issued.token) == .staleVersion)
        let laterSent = try await h.outgoing()
        #expect(try CloudRecordCodec().decode(laterSent) == afterFirstACK.last?.mutation.savedRecordVersion?.record)
        await h.transport.receiveSentChanges(savedRecords: [laterSent], deletedRecordIDs: [])
        await until { probe.cleanups == 2 }
        #expect(try h.f.journal.pendingVersioned() == unrelated)
        #expect(try h.f.checkpoints.load() == afterRetryCanonical)
        #expect(try h.f.checkpoints.load()?.records.filter { $0.id != id } == canonical.records.filter { $0.id != id })
        #expect(try evidenceFile.load() == evidence)
        let afterPhoto = try SyncRegularFileReader().read(photoURL, maximumBytes: 100_000_000)
        #expect(afterPhoto.data == photo.data && afterPhoto.inode == photo.inode && afterPhoto.device == photo.device)
        for (url, original) in staged {
            let current = try SyncRegularFileReader().read(url, maximumBytes: 100_000_000)
            #expect(current.data == original.data && current.inode == original.inode && current.device == original.device)
        }
        #expect(committer.calls == 3 && probe.handoffs == 2 && probe.accepted == 1)
    }

    @Test func actualWorkerConflictCommitsAndVerifiesExactSuccess() async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        var events = h.transport.events.makeAsyncIterator()
        try await h.start(); _ = await events.next()
        let outgoing = try await h.outgoing()
        await h.transport.receiveFailedSave(outgoing, error: h.conflict())
        let (input, epoch) = try h.input(try #require(await events.next()))
        guard case let .committed(resolution) = try await h.adapter.commitServerRecordChanged(input: input, accountEpoch: epoch) else { Issue.record("Expected commit"); return }
        let queue = try h.f.journal.pendingVersioned()
        #expect(try await h.transport.resolveFailedMutation(resolution, accountEpoch: epoch, expectedQueue: queue) == .accepted)
        #expect(h.f.store.project(id: h.f.projectID)?.name == "Remote")
        #expect(queue.map { $0.token.journalRevision } == [1])
        let retry = try await h.outgoing()
        await h.transport.receiveSentChanges(savedRecords: [retry], deletedRecordIDs: [])
        guard case let .sent(token, attemptID, sentEpoch)? = await events.next() else { Issue.record("Expected sent"); return }
        try await h.transport.verifySentMutation(token, attemptID: attemptID, accountEpoch: sentEpoch)
        #expect(try h.f.journal.acknowledgeCurrentVersion(token) == .acknowledged)
        try await h.transport.acknowledgeSentMutation(token, attemptID: attemptID)
        await #expect(throws: CloudSyncTransportError.staleOperation) { try await h.transport.verifySentMutation(token, attemptID: attemptID, accountEpoch: sentEpoch) }
        #expect(try h.f.journal.pending().isEmpty)
    }

    @Test func staleSentQueuedBeforeRebasePreservesSameIDNewRevision() async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        try await h.start()
        let issued = try #require(h.f.journal.pendingVersioned().first)
        let outgoing = try await h.outgoing()
        await h.transport.receiveSentChanges(savedRecords: [outgoing], deletedRecordIDs: [])
        _ = try await h.adapter.commitServerRecordChanged(input: h.input(attempted: issued, attemptID: UUID()), accountEpoch: h.f.epoch())
        let rebased = try h.f.journal.pendingVersioned()
        let probe = ConflictTransportProbe(h.transport)
        let coordinator = h.coordinator(transport: probe)
        await coordinator.start()
        await until { probe.verificationAttempts == 1 }
        #expect(try h.f.journal.pendingVersioned() == rebased)
        #expect(rebased.first?.token.journalRevision == 1)
        #expect(coordinator.status.lastCompleteSuccess == nil)
        #expect(probe.cleanups == 0)
    }

    @Test(arguments: [false, true]) func oneSharedThreeAttemptBudget(exhaust: Bool) async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        let committer = ConflictCommitProbe(h.adapter, staleCount: exhaust ? 2 : 1)
        let probe = ConflictTransportProbe(h.transport, staleCount: 1)
        let coordinator = h.coordinator(transport: probe, committer: committer)
        await coordinator.start(); await h.transport.receiveZoneReady(h.f.zone)
        let outgoing = try await h.outgoing()
        await h.transport.receiveFailedSave(outgoing, error: h.conflict())
        await until { exhaust ? coordinator.status.issue == .durableCommit : probe.accepted == 1 }
        #expect(committer.calls == 3)
        #expect(probe.handoffs == (exhaust ? 1 : 2))
        #expect(try h.f.journal.pendingVersioned().first?.token.journalRevision == 1)
        #expect(coordinator.status.lastCompleteSuccess == nil)
    }

    @Test func unscheduledSuffixFailsBoundedlyThenRestartPreservesLocalEdit() async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        let committer = ConflictCommitProbe(h.adapter)
        committer.afterFirstCommit = { try h.rename("Later edit") }
        let probe = ConflictTransportProbe(h.transport)
        let coordinator = h.coordinator(transport: probe, committer: committer)
        await coordinator.start(); await h.transport.receiveZoneReady(h.f.zone)
        let outgoing = try await h.outgoing()
        await h.transport.receiveFailedSave(outgoing, error: h.conflict())
        await until { coordinator.status.issue == .durableCommit }
        #expect(committer.calls == 3)
        #expect(probe.accepted == 0)
        let queue = try h.f.journal.pendingVersioned()
        #expect(queue.count == 2)
        #expect(queue.last?.mutation.savedRecordVersion?.record.payload.fields["name"]?.value == .string("Later edit"))
        #expect(try h.f.freshStore().project(id: h.f.projectID)?.name == "Later edit")
        let restarted = h.newTransport()
        try await restarted.start(); try await restarted.schedule(queue)
        try await restarted.finishMutationReplay(); await restarted.receiveZoneReady(h.f.zone)
        for expected in queue {
            let sent = try #require(await restarted.recordZoneChangeBatch(pendingChanges: [.saveRecord(h.server.recordID)], scope: .all)?.recordsToSave.first)
            #expect(try CloudRecordCodec().decode(sent) == expected.mutation.savedRecordVersion?.record)
            await restarted.receiveSentChanges(savedRecords: [sent], deletedRecordIDs: [])
        }
        #expect(try h.f.journal.pendingVersioned() == queue)
    }

    @Test func changedPayloadSuffixServerBaseAndOldAttemptCannotAuthorizeHandoff() async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        var events = h.transport.events.makeAsyncIterator()
        try await h.start(); _ = await events.next()
        let outgoing = try await h.outgoing()
        await h.transport.receiveFailedSave(outgoing, error: h.conflict())
        let (input, epoch) = try h.input(try #require(await events.next()))
        guard case let .committed(resolution) = try await h.adapter.commitServerRecordChanged(input: input, accountEpoch: epoch) else { Issue.record("Expected commit"); return }
        let queue = try h.f.journal.pendingVersioned()
        let forged = try SyncVersionedMutation(mutation: input.failedMutation, journalRevision: queue[0].token.journalRevision)
        #expect(try await h.transport.resolveFailedMutation(resolution, accountEpoch: epoch, expectedQueue: [forged]) == .stale)
        for kind in ["attempt", "body", "account"] {
            var raw = input.serverRecord
            if kind == "body", let field = raw.payload.fields["name"] { raw.payload.fields["name"] = .init(value: .string("Forged server"), stamp: field.stamp) }
            let other = try SyncConflictInput(accountIDHash: kind == "account" ? String(repeating: "a", count: 64) : input.accountIDHash,
                failedAttemptID: kind == "attempt" ? UUID() : input.failedAttemptID, failedMutation: input.failedMutation,
                failedVersion: input.failedVersion, serverRecord: raw, expectedRecordQueue: input.expectedRecordQueue, expectedVersions: input.expectedVersions)
            let counterfeit = try SyncConflictResolution(transactionID: resolution.transactionID, input: other,
                replacement: resolution.replacement, followingReplacements: resolution.followingReplacements, versions: resolution.versions)
            #expect(try await h.transport.resolveFailedMutation(counterfeit, accountEpoch: epoch, expectedQueue: queue) == .stale)
        }
        let archive = FixtureTagArchiver(requiringSecureCoding: true)
        h.server.encodeSystemFields(with: archive); archive.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        decoder.requiresSecureCoding = true
        let wrong = try #require(CKRecord(coder: decoder)); decoder.finishDecoding()
        #expect(wrong.recordChangeTag == "changed-server-tag")
        try h.system.save(wrong, accountIdentifier: "adapter-user")
        await #expect(throws: CloudSyncTransportError.invalidReplacement) { try await h.transport.resolveFailedMutation(resolution, accountEpoch: epoch, expectedQueue: queue) }
        try h.system.save(h.server, accountIdentifier: "adapter-user")
        #expect(try await h.transport.resolveFailedMutation(resolution, accountEpoch: epoch, expectedQueue: queue) == .accepted)
        let retry = try await h.outgoing()
        await h.transport.receiveFailedSave(retry, error: h.conflict()); _ = await events.next()
        #expect(try await h.transport.resolveFailedMutation(resolution, accountEpoch: epoch, expectedQueue: queue) == .stale)
        await h.transport.receiveFailedSave(outgoing, error: h.conflict())
        try h.rename("Suffix")
        #expect(try await h.transport.resolveFailedMutation(resolution, accountEpoch: epoch, expectedQueue: h.f.journal.pendingVersioned()) == .stale)
        #expect(try h.f.journal.pending().count == 2)
    }

    @Test func accountGenerationRejectsOldSuccess() async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        var events = h.transport.events.makeAsyncIterator()
        try await h.start(); _ = await events.next()
        let outgoing = try await h.outgoing()
        await h.transport.receiveSentChanges(savedRecords: [outgoing], deletedRecordIDs: [])
        guard case let .sent(token, id, epoch)? = await events.next() else { Issue.record("Expected sent"); return }
        await #expect(throws: CloudSyncTransportError.staleOperation) { try await h.transport.verifySentMutation(token, attemptID: id, accountEpoch: h.f.epoch()) }
        await h.transport.receiveAccountChange(previous: "adapter-user", current: "other")
        await #expect(throws: CloudSyncAccountEpochError.stale) { try await h.transport.verifySentMutation(token, attemptID: id, accountEpoch: epoch) }
        await h.transport.receiveSentChanges(savedRecords: [outgoing], deletedRecordIDs: [])
        #expect(try h.f.journal.pending().count == 1)
    }

    @Test func sameAttemptAfterScheduledLocalEditPreservesObservedCausalRevision() async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        var events = h.transport.events.makeAsyncIterator()
        try await h.start(); _ = await events.next()
        let outgoing = try await h.outgoing()
        await h.transport.receiveFailedSave(outgoing, error: h.conflict())
        let (original, epoch) = try h.input(try #require(await events.next()))
        _ = try await h.adapter.commitServerRecordChanged(input: original, accountEpoch: epoch)
        try h.rename("Later local edit")
        let current = try h.f.journal.pendingVersioned()
        #expect((current.last?.mutation.savedRecordVersion?.record.payload.fields["name"]?.stamp.logicalRevision ?? 0) > 1000)
        try await h.transport.schedule(current)
        let retry = try SyncConflictInput(accountIDHash: original.accountIDHash, failedAttemptID: original.failedAttemptID,
            failedMutation: original.failedMutation, failedVersion: original.failedVersion, serverRecord: original.serverRecord,
            expectedRecordQueue: current.map(\.mutation), expectedVersions: current.map(\.token))
        guard case let .committed(resolution) = try await h.adapter.commitServerRecordChanged(input: retry, accountEpoch: epoch) else { Issue.record("Expected extended candidate"); return }
        let extended = try h.f.journal.pendingVersioned()
        #expect(try await h.transport.resolveFailedMutation(resolution, accountEpoch: epoch, expectedQueue: extended) == .accepted)
        #expect(extended.map { $0.token.journalRevision } == [2, 1])
        #expect(h.f.store.project(id: h.f.projectID)?.name == "Later local edit")
    }

    @Test(arguments: [false, true]) func finalJournalCASAndEpochRecheckAfterVerificationAwait(invalidate: Bool) async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        let issued = try #require(h.f.journal.pendingVersioned().first)
        let input = try h.input(attempted: issued, attemptID: UUID())
        let probe = ConflictTransportProbe(h.transport)
        let coordinator = h.coordinator(transport: probe)
        probe.afterVerification = { epoch in
            if invalidate { epoch.invalidate() }
            else { _ = try await h.adapter.commitServerRecordChanged(input: input, accountEpoch: epoch) }
        }
        await coordinator.start(); await h.transport.receiveZoneReady(h.f.zone)
        let outgoing = try await h.outgoing()
        await h.transport.receiveSentChanges(savedRecords: [outgoing], deletedRecordIDs: [])
        await until { probe.verifications == 1 }
        await until { invalidate || (try? h.f.journal.pendingVersioned().first?.token.journalRevision) == 1 }
        #expect(try h.f.journal.pending().count == 1)
        #expect(probe.cleanups == 0)
    }

    @Test func rawServerDeletionWithoutLocalProofCannotCommit() async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        let issued = try #require(h.f.journal.pendingVersioned().first)
        let before = try h.f.checkpoints.load()
        var server = try CloudRecordCodec().decode(h.server)
        server.deletedAt = .init(value: Date(timeIntervalSince1970: 2_200_000_000), stamp: server.deletedAt.stamp)
        let input = try SyncConflictInput(accountIDHash: h.f.account.accountIDHash, failedAttemptID: UUID(), failedMutation: issued.mutation,
            failedVersion: issued.token, serverRecord: server, expectedRecordQueue: [issued.mutation], expectedVersions: [issued.token])
        await #expect(throws: SyncRemoteBatchError.unprovenDeletion) { try await h.adapter.commitServerRecordChanged(input: input, accountEpoch: h.f.epoch()) }
        #expect(try h.f.checkpoints.load() == before)
        #expect(try h.f.journal.pendingVersioned() == [issued])
    }

    @Test(arguments: [false, true]) func acceptedHandoffKicksSendAndRechecksAccountAfterAwait(invalidate: Bool) async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        var events = h.transport.events.makeAsyncIterator()
        try await h.start(); _ = await events.next()
        let outgoing = try await h.outgoing()
        await h.transport.receiveFailedSave(outgoing, error: h.conflict())
        let (input, epoch) = try h.input(try #require(await events.next()))
        guard case let .committed(resolution) = try await h.adapter.commitServerRecordChanged(input: input, accountEpoch: epoch) else { Issue.record("Expected commit"); return }
        let queue = try h.f.journal.pendingVersioned()
        let transport = h.transport, driver = h.driver
        await driver.setSendAction {
            if invalidate { await transport.receiveAccountChange(previous: "adapter-user", current: "other") }
            else if let batch = await transport.recordZoneChangeBatch(pendingChanges: driver.pendingChanges(), scope: .all) {
                await transport.receiveSentChanges(savedRecords: batch.recordsToSave, deletedRecordIDs: [])
            }
        }
        if invalidate {
            await #expect(throws: CloudSyncAccountEpochError.stale) { try await transport.resolveFailedMutation(resolution, accountEpoch: epoch, expectedQueue: queue) }
        } else {
            #expect(try await transport.resolveFailedMutation(resolution, accountEpoch: epoch, expectedQueue: queue) == .accepted)
            guard case let .sent(token, attemptID, sentEpoch)? = await events.next() else { Issue.record("Kick must send replacement"); return }
            #expect(token == queue[0].token)
            try await transport.verifySentMutation(token, attemptID: attemptID, accountEpoch: sentEpoch)
        }
        #expect(try h.f.journal.pendingVersioned() == queue)
    }

    @Test(arguments: [false, true]) func attachmentOldAttemptAndSameContentNewRevisionPreserveExactFiles(rebase: Bool) async throws {
        let fixture = try StateStoreFixture(); defer { fixture.remove() }
        let mutation = try integrationAttachment(root: fixture.root)
        let journal = FileSyncMutationJournal(url: fixture.root.appendingPathComponent("journal"))
        try journal.enqueue(mutation)
        let staging = try CloudAssetStagingService(rootURL: fixture.root.appendingPathComponent("assets"), accountIdentifier: "account")
        let transport = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store,
            initialAccountIdentifier: "account", assetStaging: staging, containerIdentifier: "test.container", engineFactory: { _, _ in TestSyncEngineDriver() })
        var events = transport.events.makeAsyncIterator()
        try await transport.start(); try await transport.schedule(journal.pendingVersioned())
        try await transport.finishMutationReplay(); await transport.receiveZoneReady(testZoneID()); _ = await events.next()
        let recordID = try CloudRecordCodec().encode(mutation.savedRecordVersion!.record, zoneID: testZoneID()).recordID
        let first = try #require(await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(recordID)], scope: .all)?.recordsToSave.first)
        let file = try #require((first["asset"] as? CKAsset)?.fileURL)
        let bytes = try Data(contentsOf: file)
        if !rebase {
            await transport.receiveFailedSave(first, error: CKError(.networkFailure)); _ = await events.next()
            let second = try #require(await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(recordID)], scope: .all)?.recordsToSave.first)
            #expect(first["syncAttemptID"] as? String != second["syncAttemptID"] as? String)
            await transport.receiveSentChanges(savedRecords: [first], deletedRecordIDs: [])
            #expect(try journal.pending().count == 1)
            #expect(try Data(contentsOf: file) == bytes)
            await transport.receiveSentChanges(savedRecords: [second], deletedRecordIDs: [])
        } else {
            await transport.receiveSentChanges(savedRecords: [first], deletedRecordIDs: [])
            let staged = try #require(journal.pending().first)
            try rebaseFixtureJournal(journal, after: staged)
            try rebaseFixtureJournal(journal, after: staged)
            let probe = ConflictTransportProbe(transport)
            let coordinator = KnitNoteCloudSyncCoordinator(transport: probe, journal: journal,
                mergeEngine: SyncMergeEngine(), recordProvider: AdapterRecordProvider(),
                fetchedBatchCommitter: UnavailableConflictCommitter(), screenshotMode: false)
            await coordinator.start()
            await until { probe.verificationAttempts == 1 }
            #expect(try journal.pendingVersioned().first?.token.journalRevision == 2)
            #expect(try Data(contentsOf: file) == bytes)
            #expect(probe.cleanups == 0)
            return
        }
        guard case let .sent(token, attemptID, epoch)? = await events.next() else { Issue.record("Expected actual success"); return }
        try await transport.verifySentMutation(token, attemptID: attemptID, accountEpoch: epoch)
        let result = try journal.acknowledgeCurrentVersion(token)
        #expect(result == .acknowledged)
        try await transport.acknowledgeSentMutation(token, attemptID: attemptID)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func actualSuccessTokenCannotAcknowledgeAToBToASameID() async throws {
        let h = try ConflictHarness(); defer { h.f.remove() }
        var events = h.transport.events.makeAsyncIterator()
        try await h.start(); _ = await events.next()
        let original = try #require(h.f.journal.pending().first)
        let outgoing = try await h.outgoing()
        await h.transport.receiveSentChanges(savedRecords: [outgoing], deletedRecordIDs: [])
        var changed = try #require(original.savedRecordVersion?.record)
        let field = try #require(changed.payload.fields["name"])
        changed.payload.fields["name"] = .init(value: .string("B"), stamp: field.stamp)
        let b = try SyncMutation.save(recordVersion: .init(record: changed), mutationID: original.mutationID)
        try rebaseFixtureJournal(h.f.journal, after: b)
        try rebaseFixtureJournal(h.f.journal, after: original)
        guard case let .sent(token, attemptID, epoch)? = await events.next() else { Issue.record("Expected success"); return }
        try await h.transport.verifySentMutation(token, attemptID: attemptID, accountEpoch: epoch)
        #expect(try h.f.journal.acknowledgeCurrentVersion(token) == .staleVersion)
        #expect(try h.f.journal.pendingVersioned().first?.mutation == original)
        #expect(try h.f.journal.pendingVersioned().first?.token.journalRevision == 2)
    }

    @Test(arguments: ["valid", "missing", "corrupt", "stale-account"]) func failedAttachmentCarriesActualStagedAttemptAndVerifiedRawServerAsset(mode: String) async throws {
        let fixture = try StateStoreFixture(); defer { fixture.remove() }
        let mutation = try integrationAttachment(root: fixture.root)
        let journal = FileSyncMutationJournal(url: fixture.root.appendingPathComponent("journal")); try journal.enqueue(mutation)
        let staging = try CloudAssetStagingService(rootURL: fixture.root.appendingPathComponent("assets"), accountIdentifier: "account")
        let system = FileCloudRecordSystemFieldsStore(url: fixture.root.appendingPathComponent("system"), zoneID: testZoneID())
        let transport = CKSyncEngineTransport(zoneID: testZoneID(), stateStore: fixture.store, systemFieldsStore: system,
            initialAccountIdentifier: "account", assetStaging: staging, containerIdentifier: "test.container", engineFactory: { _, _ in TestSyncEngineDriver() })
        var events = transport.events.makeAsyncIterator()
        try await transport.start(); try await transport.schedule(journal.pendingVersioned())
        try await transport.finishMutationReplay(); await transport.receiveZoneReady(testZoneID()); _ = await events.next()
        let server = try CloudRecordCodec().encode(mutation.savedRecordVersion!.record, zoneID: testZoneID())
        let version = try #require(mutation.savedRecordVersion?.record.payload.attachment)
        if mode == "corrupt" {
            let bad = fixture.root.appendingPathComponent("bad-server-asset")
            try Data("corrupt".utf8).write(to: bad)
            server["asset"] = CKAsset(fileURL: bad)
        } else if mode != "missing" { server["asset"] = CKAsset(fileURL: mutation.attachmentSource!.fileURL) }
        let outgoing = try #require(await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(server.recordID)], scope: .all)?.recordsToSave.first)
        if mode == "stale-account" { await transport.receiveAccountChange(previous: "account", current: "other") }
        await transport.receiveFailedSave(outgoing, error: CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]))
        if mode != "valid" {
            if mode != "stale-account" {
                guard case .mutationFailed(_, _, .statePersistence, _, _, _)? = await events.next() else { Issue.record("Bad source must fail before conflict authority"); return }
            }
            #expect(throws: (any Error).self) { try staging.installedDownload(version: version) }
            #expect(try journal.pending().count == 1)
            return
        }
        guard case let .mutationFailed(_, _, .serverRecordChanged, _, _, attempted)? = await events.next() else { Issue.record("Expected actual conflict"); return }
        #expect(attempted.mutation.attachmentSource?.fileURL == (outgoing["asset"] as? CKAsset)?.fileURL)
        #expect(attempted.token == (try journal.pendingVersioned().first?.token))
        let installed = try staging.installedDownload(version: version)
        #expect(try Data(contentsOf: installed) == Data(contentsOf: mutation.attachmentSource!.fileURL))
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; try? await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }
}

// Native journal fixture authority isolates ACK semantics from Core materialization.
@MainActor private func rebaseFixtureJournal(_ journal: FileSyncMutationJournal, after: SyncMutation) throws {
    try journal.withExclusivePending { lease in
        let all = try lease.pendingVersioned()
        let before = try #require(all.first)
        let input = try SyncConflictInput(accountIDHash: String(repeating: "a", count: 64), failedAttemptID: UUID(),
            failedMutation: before.mutation, failedVersion: before.token, serverRecord: after.savedRecordVersion!.record,
            expectedRecordQueue: all.map(\.mutation), expectedVersions: all.map(\.token))
        let transition = try SyncJournalRebaseTransition(transactionID: UUID(), input: input,
            predecessorPendingSHA256: SyncConflictRebaseCoding.pendingDigest(all), predecessorRebaseHeadSHA256: lease.rebaseHistoryHeadSHA256(),
            recordPositions: [0], before: [before.mutation], after: [after], beforeVersions: [before.token],
            afterVersions: [SyncMutationVersionToken(mutation: after, journalRevision: before.token.journalRevision + 1)])
        #expect(try lease.rebase(transition))
    }
}

// Synthetic server metadata only. ETag was observed in this SDK's secure
// encodeSystemFields archive; CKRecord(coder:) validates the complete fixture.
private final class FixtureTagArchiver: NSKeyedArchiver {
    override func encode(_ object: Any?, forKey key: String) {
        super.encode(key == "ETag" ? "changed-server-tag" : object, forKey: key)
    }
}

private enum ConflictContinuationFault: Error { case injected }

@MainActor private final class ConflictContinuationGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    var isSuspended: Bool { continuation != nil }
    func suspend() async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func resume() { let pending = continuation; continuation = nil; pending?.resume() }
}

// Real kind-5 ACK append succeeds durably, then its IO boundary throws before
// native cleanup. A later pending() would remove this file and append kind 3.
@MainActor private struct ConflictCleanupResidue {
    let root: URL
    let staged: URL
    init(_ fixture: AdapterFixture) throws {
        root = fixture.journal.recoveryLocation.deletingLastPathComponent()
        let mutation = try integrationAttachment(root: fixture.root)
        try fixture.journal.enqueue(mutation)
        let current = try #require(try fixture.journal.pendingVersioned().first {
            $0.mutation.identity == mutation.identity
        })
        staged = try #require(current.mutation.attachmentSource?.fileURL)
        let interrupted = FileSyncMutationJournal(url: fixture.journal.recoveryLocation, appendFrames: { bytes, url in
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: bytes); try handle.synchronize()
            throw ConflictContinuationFault.injected
        })
        #expect(throws: ConflictContinuationFault.injected) {
            _ = try interrupted.acknowledgeCurrentVersion(current.token)
        }
        #expect(FileManager.default.fileExists(atPath: staged.path))
    }
    func snapshot() throws -> [String: Data] {
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in files {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true { result[url.path + "/"] = Data() }
            if values.isRegularFile == true { result[url.path] = try Data(contentsOf: url) }
        }
        return result
    }
}

@MainActor private final class ConflictHarness {
    let f: AdapterFixture
    let system: FileCloudRecordSystemFieldsStore
    let transport: CKSyncEngineTransport
    let adapter: JSONProjectStoreRemoteBatchCommitter
    let server: CKRecord
    let driver: TestSyncEngineDriver
    init() throws {
        f = try AdapterFixture()
        try f.store.updateProject(id: f.projectID, name: "Local", toolType: nil, toolSize: nil, toolNotes: nil, photoChange: .unchanged)
        system = FileCloudRecordSystemFieldsStore(url: f.root.appendingPathComponent("system.json"), zoneID: f.zone)
        server = try CloudRecordCodec().encode(f.batch().records[0], zoneID: f.zone)
        let driver = TestSyncEngineDriver(); self.driver = driver
        transport = CKSyncEngineTransport(zoneID: f.zone, stateStore: .init(url: f.root.appendingPathComponent("engine.json")), systemFieldsStore: system, initialAccountIdentifier: "adapter-user", containerIdentifier: "test.container", engineFactory: { _, _ in driver })
        adapter = f.adapter { _ in }
    }
    func newTransport() -> CKSyncEngineTransport { CKSyncEngineTransport(zoneID: f.zone, stateStore: .init(url: f.root.appendingPathComponent("restart-engine.json")), systemFieldsStore: system, initialAccountIdentifier: "adapter-user", containerIdentifier: "test.container", engineFactory: { _, _ in TestSyncEngineDriver() }) }
    func rename(_ value: String) throws { try f.store.updateProject(id: f.projectID, name: value, toolType: nil, toolSize: nil, toolNotes: nil, photoChange: .unchanged) }
    func start() async throws { try await transport.start(); try await transport.schedule(f.journal.pendingVersioned()); try await transport.finishMutationReplay(); await transport.receiveZoneReady(f.zone) }
    func outgoing() async throws -> CKRecord {
        for _ in 0..<1000 {
            if let record = await transport.recordZoneChangeBatch(pendingChanges: [.saveRecord(server.recordID)], scope: .all)?.recordsToSave.first { return record }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw SyncConflictError.missingAuthority
    }
    func conflict() -> CKError { CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]) }
    func input(_ event: CloudSyncEvent) throws -> (SyncConflictInput, CloudSyncAccountEpoch) {
        guard case let .mutationFailed(_, _, _, epoch, attempt, attempted) = event else { throw SyncConflictError.invalidInput }
        return (try input(attempted: attempted, attemptID: attempt), epoch)
    }
    func input(attempted: SyncVersionedMutation, attemptID: UUID) throws -> SyncConflictInput {
        let queue = try f.journal.pendingVersioned()
        return try .init(accountIDHash: f.account.accountIDHash, failedAttemptID: attemptID, failedMutation: attempted.mutation, failedVersion: attempted.token, serverRecord: CloudRecordCodec().decode(server), expectedRecordQueue: queue.map(\.mutation), expectedVersions: queue.map(\.token))
    }
    func coordinator(transport overrideTransport: (any CloudSyncTransport)? = nil,
        committer: (any SyncFetchedBatchCommitting)? = nil, journal: FileSyncMutationJournal? = nil) -> KnitNoteCloudSyncCoordinator {
        KnitNoteCloudSyncCoordinator(transport: overrideTransport ?? transport, journal: journal ?? f.journal, mergeEngine: SyncMergeEngine(), recordProvider: AdapterRecordProvider(), fetchedBatchCommitter: committer ?? adapter, screenshotMode: false)
    }
}

@MainActor private final class ConflictCommitProbe: SyncFetchedBatchCommitting {
    let base: JSONProjectStoreRemoteBatchCommitter
    var calls = 0
    var staleCount: Int
    var afterFirstCommit: (() throws -> Void)?
    var firstAttempt: (token: SyncMutationVersionToken, id: UUID, epoch: CloudSyncAccountEpoch)?
    init(_ base: JSONProjectStoreRemoteBatchCommitter, staleCount: Int = 0) { self.base = base; self.staleCount = staleCount }
    func commitServerRecordChanged(input: SyncConflictInput, accountEpoch: CloudSyncAccountEpoch) async throws -> SyncConflictCommitResult {
        calls += 1
        if firstAttempt == nil { firstAttempt = (input.failedVersion, input.failedAttemptID, accountEpoch) }
        if staleCount > 0 { staleCount -= 1; return .stalePredecessor }
        let result = try await base.commitServerRecordChanged(input: input, accountEpoch: accountEpoch)
        if let action = afterFirstCommit { afterFirstCommit = nil; try action() }
        return result
    }
    func commitFetchedBatch(batch: SyncRemoteBatch, accountEpoch: CloudSyncAccountEpoch) async throws { try await base.commitFetchedBatch(batch: batch, accountEpoch: accountEpoch) }
    func didAcknowledgeFetchedBatch(batch: SyncRemoteBatchIdentity, accountEpoch: CloudSyncAccountEpoch) async throws { try await base.didAcknowledgeFetchedBatch(batch: batch, accountEpoch: accountEpoch) }
}

@MainActor private final class ConflictTransportProbe: CloudSyncTransport {
    nonisolated let events: AsyncStream<CloudSyncEvent>
    let base: CKSyncEngineTransport
    var handoffs = 0
    var accepted = 0
    var staleCount: Int
    init(_ base: CKSyncEngineTransport, staleCount: Int = 0) { self.base = base; events = base.events; self.staleCount = staleCount }
    var beforeFirstStaleHandoff: (() async throws -> Void)?
    func start() async throws { try await base.start() }
    func schedule(_ mutations: [SyncVersionedMutation]) async throws { try await base.schedule(mutations) }
    func finishMutationReplay(completionID: UUID?) async throws { try await base.finishMutationReplay(completionID: completionID) }
    func acknowledgeFetchedBatch(_ batchID: UUID) async throws { try await base.acknowledgeFetchedBatch(batchID) }
    func verifyFetchedBatchAcknowledgement(_ batchID: UUID) async throws { try await base.verifyFetchedBatchAcknowledgement(batchID) }
    func finishFetchedBatchAcknowledgement(_ identity: SyncRemoteBatchIdentity) async throws { try await base.finishFetchedBatchAcknowledgement(identity) }
    var afterVerification: ((CloudSyncAccountEpoch) async throws -> Void)?
    var verifications = 0
    var verificationAttempts = 0
    var cleanups = 0
    var afterCleanup: (() async throws -> Void)?
    var afterHandoff: (() async throws -> Void)?
    func verifySentMutation(_ token: SyncMutationVersionToken, attemptID: UUID, accountEpoch: CloudSyncAccountEpoch) async throws {
        verificationAttempts += 1
        try await base.verifySentMutation(token, attemptID: attemptID, accountEpoch: accountEpoch)
        if let action = afterVerification { afterVerification = nil; try await action(accountEpoch) }
        verifications += 1
    }
    func acknowledgeSentMutation(_ token: SyncMutationVersionToken, attemptID: UUID) async throws {
        cleanups += 1
        try await base.acknowledgeSentMutation(token, attemptID: attemptID)
        if let action = afterCleanup { afterCleanup = nil; try await action() }
    }
    func resolveFailedMutation(_ resolution: SyncConflictResolution, accountEpoch: CloudSyncAccountEpoch, expectedQueue: [SyncVersionedMutation]) async throws -> CloudConflictHandoffResult {
        handoffs += 1
        if staleCount > 0 {
            staleCount -= 1
            if let action = beforeFirstStaleHandoff { beforeFirstStaleHandoff = nil; try await action() }
            return .stale
        }
        let result = try await base.resolveFailedMutation(resolution, accountEpoch: accountEpoch, expectedQueue: expectedQueue)
        if let action = afterHandoff { afterHandoff = nil; try await action() }
        if result == .accepted { accepted += 1 }; return result
    }
    func fetchNow(completionID: UUID?) async throws { try await base.fetchNow(completionID: completionID) }
    func sendNow(completionID: UUID?) async throws { try await base.sendNow(completionID: completionID) }
}

private struct UnavailableConflictCommitter: SyncFetchedBatchCommitting {
    func commitServerRecordChanged(input: SyncConflictInput, accountEpoch: CloudSyncAccountEpoch) async throws -> SyncConflictCommitResult { throw SyncConflictError.missingAuthority }
    func commitFetchedBatch(batch: SyncRemoteBatch, accountEpoch: CloudSyncAccountEpoch) async throws { throw SyncConflictError.missingAuthority }
    func didAcknowledgeFetchedBatch(batch: SyncRemoteBatchIdentity, accountEpoch: CloudSyncAccountEpoch) async throws { throw SyncConflictError.missingAuthority }
}
