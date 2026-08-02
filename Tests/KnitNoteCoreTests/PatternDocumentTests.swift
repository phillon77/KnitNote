import Foundation
import Testing
@testable import KnitNoteCore

@Test func pdfScalePolicyConvertsBetweenFitWidthRatioAndAbsoluteScale() {
    #expect(PatternPDFScalePolicy.ratio(currentScale: 1.8, fitWidthScale: 1.2) == 1.5)
    #expect(PatternPDFScalePolicy.absoluteScale(
        ratio: 1.5,
        fitWidthScale: 0.9,
        allowed: 0.5...3.0
    ) == 1.35)
}

@Test func pdfScalePolicyFallsBackAndClampsAtPDFKitLimits() {
    #expect(PatternPDFScalePolicy.ratio(currentScale: .infinity, fitWidthScale: 1.0) == 1.0)
    #expect(PatternPDFScalePolicy.ratio(currentScale: 2.0, fitWidthScale: 0.0) == 1.0)
    #expect(PatternPDFScalePolicy.absoluteScale(ratio: 8.0, fitWidthScale: 0.5, allowed: 0.25...2.0) == 2.0)
    #expect(PatternPDFScalePolicy.absoluteScale(ratio: -1.0, fitWidthScale: 0.8, allowed: 0.25...2.0) == 0.8)
}

@Test func pendingPDFScaleCaptureFlushesUserWidthBeforeDebounceSettles() throws {
    var gate = PatternPDFScaleCaptureGate()
    let observedRevision = gate.observe(
        currentScale: 1.92,
        fitWidthScale: 1.2,
        context: 7
    )
    let revision = try #require(observedRevision)

    #expect(gate.flush(context: 7) == 1.6)
    #expect(gate.settle(revision: revision, context: 7, liveScale: 1.92) == nil)
}

@Test func newerPDFScaleObservationSupersedesStaleDelayedCallback() throws {
    var gate = PatternPDFScaleCaptureGate()
    let observedStaleRevision = gate.observe(
        currentScale: 1.2,
        fitWidthScale: 1.0,
        context: 11
    )
    let staleRevision = try #require(observedStaleRevision)
    let observedLatestRevision = gate.observe(
        currentScale: 1.6,
        fitWidthScale: 1.0,
        context: 11
    )
    let latestRevision = try #require(observedLatestRevision)

    #expect(gate.settle(revision: staleRevision, context: 11, liveScale: 1.2) == nil)
    #expect(gate.settle(revision: latestRevision, context: 11, liveScale: 1.6) == 1.6)
}

@Test func changedPDFScaleContextDiscardsOldPendingObservation() throws {
    var gate = PatternPDFScaleCaptureGate()
    let observedStaleRevision = gate.observe(
        currentScale: 1.5,
        fitWidthScale: 1.0,
        context: 19
    )
    let staleRevision = try #require(observedStaleRevision)

    #expect(gate.settle(revision: staleRevision, context: 20, liveScale: 1.5) == nil)
    #expect(gate.flush(context: 19) == nil)
}

@Test func ignoredProgrammaticTargetScaleClearsEarlierPendingUserWidth() throws {
    var gate = PatternPDFScaleCaptureGate()
    let observedRevision = gate.observe(
        currentScale: 1.5,
        fitWidthScale: 1.0,
        context: 23
    )
    _ = try #require(observedRevision)

    let latestVisibleScale = 1.0
    let programmaticTarget = 1.0
    #expect(latestVisibleScale == programmaticTarget)
    gate.discardPendingObservation(context: 23)

    #expect(gate.flush(context: 23) == nil)
}

@Test func liveScaleMismatchSettlementConsumesPendingUserWidth() throws {
    var gate = PatternPDFScaleCaptureGate()
    let observedRevision = gate.observe(
        currentScale: 1.5,
        fitWidthScale: 1.0,
        context: 29
    )
    let revision = try #require(observedRevision)

    #expect(gate.settle(revision: revision, context: 29, liveScale: 1.0) == nil)
    #expect(gate.flush(context: 29) == nil)
}

@Test func pdfWidthRatioIsSharedAcrossPagesWithoutChangingPageDetails() {
    var state = PatternReadingState(
        pageIndex: 0,
        pdfWidthScaleRatio: 1.6,
        highlightPosition: 0.2,
        pageNote: "body",
        pageStates: [1: .init(horizontalPosition: 0.8, verticalPosition: 0.3, note: "sleeve")]
    )

    state.transitionToPDFPage(1)

    #expect(state.pdfWidthScaleRatio == 1.6)
    #expect(state.pageNote == "sleeve")
    #expect(state.highlightPosition == 0.8)
}

@Test(arguments: [
    ("legacy", nil),
    ("zero", "0"),
    ("negative", "-1"),
    ("nan", "\"NaN\""),
    ("infinity", "\"Infinity\""),
]) func decodingMissingOrInvalidPDFWidthRatioUsesDefault(
    _: String,
    ratioJSON: String?
) throws {
    var fields = [
        "\"pageIndex\": 3",
        "\"zoomScale\": 2.5",
        "\"offsetX\": 0.2",
        "\"offsetY\": 0.8",
        "\"highlightEnabled\": true",
        "\"highlightPosition\": 0.3",
        "\"highlightMode\": \"cross\"",
        "\"verticalHighlightPosition\": 0.7",
        "\"pageNote\": \"neck shaping\"",
        "\"pageStates\": {\"3\": {\"horizontalPosition\": 0.3, \"verticalPosition\": 0.7, \"note\": \"neck shaping\"}}",
    ]
    if let ratioJSON {
        fields.append("\"pdfWidthScaleRatio\": \(ratioJSON)")
    }
    let fixture = "{\(fields.joined(separator: ","))}"
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
        positiveInfinity: "Infinity",
        negativeInfinity: "-Infinity",
        nan: "NaN"
    )

    let decoded = try decoder.decode(PatternReadingState.self, from: Data(fixture.utf8))

    #expect(decoded.pdfWidthScaleRatio == 1.0)
}

@Test func richReadingStateRoundTripsPDFWidthRatioAndExistingPageDetails() throws {
    let expected = PatternReadingState(
        pageIndex: 4,
        pdfWidthScaleRatio: 1.75,
        zoomScale: 2.25,
        offsetX: 0.15,
        offsetY: 0.8,
        highlightEnabled: true,
        highlightPosition: 0.31,
        highlightMode: .cross,
        verticalHighlightPosition: 0.72,
        pageNote: "neck shaping",
        pageStates: [
            4: .init(horizontalPosition: 0.31, verticalPosition: 0.72, note: "neck shaping"),
            7: .init(horizontalPosition: 0.63, verticalPosition: 0.19, note: "sleeve repeat"),
        ]
    )

    let decoded = try JSONDecoder().decode(
        PatternReadingState.self,
        from: JSONEncoder().encode(expected)
    )

    #expect(decoded.pdfWidthScaleRatio == 1.75)
    #expect(decoded.pageIndex == 4)
    #expect(decoded.zoomScale == 2.25)
    #expect(decoded.offsetX == 0.15)
    #expect(decoded.offsetY == 0.8)
    #expect(decoded.highlightEnabled)
    #expect(decoded.highlightPosition == 0.31)
    #expect(decoded.highlightMode == .cross)
    #expect(decoded.verticalHighlightPosition == 0.72)
    #expect(decoded.pageNote == "neck shaping")
    #expect(decoded.pageStates == expected.pageStates)
}

@Test func everyIOSDeviceUsesFullScreenPatternPresentation() {
    #expect(patternReaderPresentation(isPad: true) == .fullScreen)
    #expect(patternReaderPresentation(isPad: false) == .fullScreen)
}

@Test func patternStateClampsAndPersistsAsV3() throws {
    var project = try StoredProject(name: "Sweater")
    let pattern = PatternDocument(displayName: "Chart", kind: .pdf, storedFilename: "one.pdf")
    project.addPattern(pattern)
    project.updatePatternState(id: pattern.id, pageIndex: 3, highlightPosition: 2)
    #expect(project.patterns[0].pageIndex == 3)
    #expect(project.patterns[0].highlightPosition == 1)
}

@Test func completeReadingStateIsClampedAndStored() throws {
    var project = try StoredProject(name: "Cardigan")
    let pattern = PatternDocument(displayName: "Sleeve", kind: .image, storedFilename: "s.png")
    project.addPattern(pattern)
    let state = PatternReadingState(pageIndex: -4, zoomScale: 0, offsetX: 0.2, offsetY: 0.7, highlightEnabled: true, highlightPosition: -1)
    project.updatePatternState(id: pattern.id, state: state)
    #expect(project.patterns[0].pageIndex == 0)
    #expect(project.patterns[0].zoomScale == 0.1)
    #expect(project.patterns[0].contentOffsetY == 0.7)
    #expect(project.patterns[0].highlightEnabled)
    #expect(project.patterns[0].highlightPosition == 0)
    #expect(project.patterns[0].contentOffsetX == 0.2)
}

@MainActor @Test func storeWritesCurrentArchiveVersion() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Sweater")
    try store.addPattern(projectID: store.projects[0].id, pattern: PatternDocument(displayName: "Chart", kind: .image, storedFilename: "x.png"))
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    #expect(object["version"] as? Int == ProjectArchive.currentVersion)
}

@Test func highlightModeDefaultsAndPositionsClamp() {
    let defaultState = PatternReadingState()
    #expect(defaultState.highlightMode == .horizontal)
    #expect(defaultState.verticalHighlightPosition == 0.5)

    let clamped = PatternReadingState(
        highlightPosition: -1,
        highlightMode: .cross,
        verticalHighlightPosition: 2
    )
    #expect(clamped.highlightPosition == 0)
    #expect(clamped.highlightMode == .cross)
    #expect(clamped.verticalHighlightPosition == 1)
}

@MainActor @Test func highlightModeAndBothPositionsSurviveStoreReload() throws {
    let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store=JSONProjectStore(url:url); try store.add(name:"Shawl"); let projectID=store.projects[0].id
    let pattern=PatternDocument(displayName:"Lace",kind:.pdf,storedFilename:"lace.pdf"); try store.addPattern(projectID:projectID,pattern:pattern)
    let expected=PatternReadingState(
        highlightEnabled:true,
        highlightPosition:0.2,
        highlightMode:.cross,
        verticalHighlightPosition:0.8,
        pageStates: [
            0: PatternPageState(horizontalPosition: 0.2, verticalPosition: 0.8),
        ]
    )
    try store.updatePatternState(projectID:projectID,id:pattern.id,state:expected)
    let actual=JSONProjectStore(url:url).projects[0].patterns[0].readingState
    #expect(actual.highlightMode == .cross)
    #expect(actual.highlightPosition == 0.2)
    #expect(actual.verticalHighlightPosition == 0.8)
}

@Test func versionThreePatternDefaultsToHorizontalHighlight() throws {
    let pattern=PatternDocument(displayName:"Legacy",kind:.pdf,storedFilename:"legacy.pdf")
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(pattern)) as? [String: Any])
    object.removeValue(forKey:"highlightMode")
    object.removeValue(forKey:"verticalHighlightPosition")

    let decoded = try JSONDecoder().decode(PatternDocument.self, from: JSONSerialization.data(withJSONObject:object))

    #expect(decoded.highlightMode == .horizontal)
    #expect(decoded.verticalHighlightPosition == 0.5)
}

@MainActor @Test func completeReadingStateSurvivesStoreReload() throws {
    let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store=JSONProjectStore(url:url); try store.add(name:"Blanket"); let projectID=store.projects[0].id
    let pattern=PatternDocument(displayName:"Chart",kind:.pdf,storedFilename:"chart.pdf"); try store.addPattern(projectID:projectID,pattern:pattern)
    let expected=PatternReadingState(
        pageIndex:5,
        zoomScale:2.5,
        offsetX:0.3,
        offsetY:0.8,
        highlightEnabled:true,
        highlightPosition:0.66,
        pageStates: [
            5: PatternPageState(horizontalPosition: 0.66),
        ]
    )
    try store.updatePatternState(projectID:projectID,id:pattern.id,state:expected)
    let actual=JSONProjectStore(url:url).projects[0].patterns[0].readingState
    #expect(actual == expected)
}

@Test func legacyReadingStateDefaultsUnsavedTargetPageExplicitFieldsWithoutMutatingDocument() {
    var pattern = PatternDocument(
        displayName: "Legacy",
        kind: .pdf,
        storedFilename: "legacy.pdf"
    )
    pattern.pageIndex = 2
    pattern.highlightPosition = 0.24
    pattern.verticalHighlightPosition = 0.76
    pattern.pageStates = [
        0: PatternPageState(
            horizontalPosition: 0.24,
            verticalPosition: 0.76,
            note: "Previous page"
        ),
    ]
    let stored = pattern

    let loaded = pattern.readingState

    #expect(loaded.highlightPosition == 0.5)
    #expect(loaded.verticalHighlightPosition == 0.5)
    #expect(loaded.pageNote.isEmpty)
    #expect(pattern == stored)
}

@Test func pdfReaderDoesNotSampleBeforeSavedPositionIsRestored() {
    var gate = PatternReadingRestoreGate()
    #expect(!gate.canSample)
    let firstBegin = gate.beginRestoring()
    let secondBegin = gate.beginRestoring()
    #expect(firstBegin)
    #expect(!secondBegin)
    #expect(!gate.canSample)

    gate.didRestore()

    #expect(gate.canSample)
}

@Test func pdfPageRequestRejectsStaleCallbacksUntilTargetIsConfirmed() {
    var gate = PatternPDFPageRequestGate()
    gate.request(2)

    let stale = gate.accepts(1)
    let confirmed = gate.accepts(2)
    let laterSwipe = gate.accepts(3)
    #expect(!stale)
    #expect(confirmed)
    #expect(laterSwipe)
    #expect(gate.requestedPageIndex == nil)
}

@Test func pdfRestorePageIsIndependentOfPageOffset() {
    let top = PatternReadingState(pageIndex: 2, offsetX: 0, offsetY: 0)
    let bottom = PatternReadingState(pageIndex: 2, offsetX: 1, offsetY: 1)

    #expect(top.pdfRestorePageIndex(pageCount: 8) == 2)
    #expect(bottom.pdfRestorePageIndex(pageCount: 8) == 2)
}

@Test func pdfAnchorCaptureUpdatesOnlyTheCurrentPagePosition() {
    var state = PatternReadingState(
        pageIndex: 2,
        pdfWidthScaleRatio: 1.6,
        offsetX: 0,
        offsetY: 0,
        highlightPosition: 0.3
    )

    state.setPDFAnchor(pageIndex: 2, offsetX: 0.25, offsetY: 0.75)

    #expect(state.pageIndex == 2)
    #expect(state.offsetX == 0.25)
    #expect(state.offsetY == 0.75)
    #expect(state.pdfWidthScaleRatio == 1.6)
    #expect(state.highlightPosition == 0.3)
}

@Test func discretePDFPageMovementClampsAndRestoresPerPageOffsets() {
    var state=PatternReadingState(pageIndex:1,offsetX:0.4,offsetY:0.7,highlightPosition:0.2,verticalHighlightPosition:0.8,pageNote:"page two")
    state.movePDFPage(by:1,pageCount:3)
    #expect(state.pageIndex == 2)
    #expect(state.offsetX == 0)
    #expect(state.offsetY == 0)
    #expect(state.highlightPosition == 0.5)
    #expect(state.pageNote.isEmpty)
    state.highlightPosition = 0.7
    state.pageNote = "page three"
    state.movePDFPage(by:1,pageCount:3)
    #expect(state.pageIndex == 2)
    state.movePDFPage(by:-9,pageCount:3)
    #expect(state.pageIndex == 0)
    state.movePDFPage(by:1,pageCount:3)
    #expect(state.pageIndex == 1)
    #expect(state.offsetX == 0.4)
    #expect(state.offsetY == 0.7)
    #expect(state.highlightPosition == 0.2)
    #expect(state.verticalHighlightPosition == 0.8)
    #expect(state.pageNote == "page two")
}

@Test func legacyPageStateWithoutOffsetsDecodesAtTheTopOfThePage() throws {
    let data = Data(#"{"horizontalPosition":0.2,"verticalPosition":0.8,"note":"row"}"#.utf8)

    let decoded = try JSONDecoder().decode(PatternPageState.self, from: data)

    #expect(decoded.offsetX == 0)
    #expect(decoded.offsetY == 0)
    #expect(decoded.horizontalPosition == 0.2)
    #expect(decoded.verticalPosition == 0.8)
    #expect(decoded.note == "row")
}

@Test func synchronizingAnUnchangedVisiblePDFPageDoesNotMutateReaderState() {
    var state = PatternReadingState(
        pageIndex: 2,
        zoomScale: 1,
        offsetX: 0,
        offsetY: 0,
        highlightEnabled: true,
        highlightPosition: 0.27,
        highlightMode: .cross,
        verticalHighlightPosition: 0.73,
        pageNote: "keep this row"
    )
    state.saveCurrentPage()
    let original = state

    let changed = state.synchronizeVisiblePDFPage(2)

    #expect(!changed)
    #expect(state == original)
}

@Test func pageStatesKeepIndependentHighlightsAndTrimNotes() {
    var state = PatternReadingState(pageIndex: 0, highlightPosition: 0.2, verticalHighlightPosition: 0.8)
    state.pageNote = "  first repeat  "
    state.saveCurrentPage()

    state.loadPage(1)
    #expect(state.highlightPosition == 0.5)
    #expect(state.verticalHighlightPosition == 0.5)
    state.highlightPosition = 0.7
    state.pageNote = "   "
    state.saveCurrentPage()

    #expect(state.pageStates[0]?.note == "first repeat")
    #expect(state.pageStates[1]?.horizontalPosition == 0.7)
    #expect(state.pageStates[1]?.note == nil)

    state.loadPage(0)
    #expect(state.highlightPosition == 0.2)
    #expect(state.verticalHighlightPosition == 0.8)
    #expect(state.pageNote == "first repeat")
}

@Test func settingPageNoteImmediatelyUpdatesActivePageState() {
    var state = PatternReadingState(pageIndex: 2)

    state.setPageNote("  sleeve repeat  ")

    #expect(state.pageNote == "sleeve repeat")
    #expect(state.pageStates[2]?.note == "sleeve repeat")
}

@MainActor @Test func pageNoteSurvivesProjectStoreReload() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Sweater")
    let projectID = store.projects[0].id
    let pattern = PatternDocument(displayName: "Sleeve", kind: .pdf, storedFilename: "sleeve.pdf")
    try store.addPattern(projectID: projectID, pattern: pattern)
    var state = PatternReadingState(pageIndex: 2)
    state.setPageNote("chart note")

    try store.updatePatternState(projectID: projectID, id: pattern.id, state: state)

    let reloaded = try #require(JSONProjectStore(url: url).projects[0].patterns.first)
    #expect(reloaded.readingState.pageNote == "chart note")
    #expect(reloaded.pageStates[2]?.note == "chart note")
}

@MainActor @Test func dedicatedPageNoteSaveSurvivesWithoutReaderState() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Cardigan")
    let projectID = store.projects[0].id
    let pattern = PatternDocument(displayName: "Chart", kind: .pdf, storedFilename: "chart.pdf")
    try store.addPattern(projectID: projectID, pattern: pattern)

    try store.savePatternPageNote(projectID: projectID, patternID: pattern.id, pageIndex: 2, text: "  iPhone note  ")

    let reloaded = try #require(JSONProjectStore(url: url).projects[0].patterns.first)
    #expect(reloaded.pageStates[2]?.note == "iPhone note")
    #expect(reloaded.pageStates[0]?.note == nil)
}

@MainActor @Test func completedProjectRejectsLegacyReaderWritesWithoutChangingArchiveOrMarkup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appendingPathComponent("projects-v1.json")
    let store = JSONProjectStore(url: archiveURL)
    try store.add(name: "Completed")
    let projectID = try #require(store.projects.first?.id)
    let pattern = PatternDocument(displayName: "Chart", kind: .pdf, storedFilename: "chart.pdf")
    try store.addPattern(projectID: projectID, pattern: pattern)
    let originalMarkup = PatternMarkupDocument(strokes: [
        .init(points: [.init(x: 0.2, y: 0.8)], color: .red, width: 0.01),
    ])
    try store.savePatternMarkup(
        originalMarkup,
        projectID: projectID,
        patternID: pattern.id,
        pageIndex: 0,
        expectedDataGeneration: store.dataGeneration
    )
    try store.markCompleted(projectID: projectID)
    let archiveBefore = try Data(contentsOf: archiveURL)
    let markupURL = root.appendingPathComponent(
        "Patterns/\(projectID.uuidString)/Markup/\(pattern.id.uuidString)/0.json"
    )
    let markupBefore = try Data(contentsOf: markupURL)

    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try store.updatePatternState(
            projectID: projectID,
            id: pattern.id,
            state: PatternReadingState(pageIndex: 2, highlightPosition: 0.2),
            expectedDataGeneration: store.dataGeneration
        )
    }
    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try store.updatePatternState(projectID: projectID, id: pattern.id, pageIndex: 3, highlightPosition: 0.7)
    }
    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try store.savePatternPageNote(projectID: projectID, patternID: pattern.id, pageIndex: 2, text: "blocked")
    }
    #expect(throws: PatternLibraryMutationError.projectCompleted) {
        try store.savePatternMarkup(
            PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.4, y: 0.4)], color: .blue, width: 0.01)]),
            projectID: projectID,
            patternID: pattern.id,
            pageIndex: 0,
            expectedDataGeneration: store.dataGeneration
        )
    }

    #expect(try Data(contentsOf: archiveURL) == archiveBefore)
    #expect(try Data(contentsOf: markupURL) == markupBefore)
    let reopened = JSONProjectStore(url: archiveURL)
    #expect(reopened.projects.first?.patterns.first?.readingState == PatternReadingState())
    #expect(try reopened.loadPatternMarkup(projectID: projectID, patternID: pattern.id, pageIndex: 0) == originalMarkup)
}

@MainActor @Test func activeProjectContinuesToPersistLegacyReaderWrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = JSONProjectStore(url: root.appendingPathComponent("projects-v1.json"))
    try store.add(name: "Active")
    let projectID = try #require(store.projects.first?.id)
    let pattern = PatternDocument(displayName: "Chart", kind: .pdf, storedFilename: "chart.pdf")
    try store.addPattern(projectID: projectID, pattern: pattern)
    try store.updatePatternState(projectID: projectID, id: pattern.id, pageIndex: 3, highlightPosition: 0.7)
    try store.savePatternPageNote(projectID: projectID, patternID: pattern.id, pageIndex: 3, text: "active")
    let markup = PatternMarkupDocument(strokes: [.init(points: [.init(x: 0.5, y: 0.5)], color: .black, width: 0.01)])
    try store.savePatternMarkup(
        markup,
        projectID: projectID,
        patternID: pattern.id,
        pageIndex: 3,
        expectedDataGeneration: store.dataGeneration
    )

    let reopened = JSONProjectStore(url: root.appendingPathComponent("projects-v1.json"))
    #expect(reopened.projects.first?.patterns.first?.readingState.pageIndex == 3)
    #expect(reopened.projects.first?.patterns.first?.pageStates[3]?.note == "active")
    #expect(try reopened.loadPatternMarkup(projectID: projectID, patternID: pattern.id, pageIndex: 3) == markup)
}

@Test func completedStoredProjectIgnoresLegacyReaderWrites() throws {
    var project = try StoredProject(name: "Completed")
    let pattern = PatternDocument(displayName: "Chart", kind: .pdf, storedFilename: "chart.pdf")
    project.addPattern(pattern)
    project.markCompleted(at: Date(timeIntervalSince1970: 100))
    let before = project

    project.updatePatternState(id: pattern.id, pageIndex: 3, highlightPosition: 0.7)
    project.savePatternPageNote(patternID: pattern.id, pageIndex: 3, text: "blocked")

    #expect(project == before)
}

@Test func legacyPatternMigratesHighlightsToItsSavedPage() throws {
    let original = PatternDocument(displayName: "Legacy", kind: .pdf, storedFilename: "legacy.pdf")
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    object["pageIndex"] = 3
    object["highlightPosition"] = 0.25
    object["verticalHighlightPosition"] = 0.75
    object.removeValue(forKey: "pageStates")

    let decoded = try JSONDecoder().decode(PatternDocument.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.pageStates[3]?.horizontalPosition == 0.25)
    #expect(decoded.pageStates[3]?.verticalPosition == 0.75)
}

@Test func patternGroupsOmitEmptyProjectsAndKeepOwners() throws {
    let empty = try StoredProject(name: "Empty")
    var scarf = try StoredProject(name: "Scarf")
    let chart = PatternDocument(displayName: "Chart", kind: .pdf, storedFilename: "chart.pdf")
    scarf.addPattern(chart)

    let groups = patternGroups(from: [empty, scarf])

    #expect(groups.count == 1)
    #expect(groups[0].id == scarf.id)
    #expect(groups[0].projectName == "Scarf")
    #expect(groups[0].patterns == [chart])
}
