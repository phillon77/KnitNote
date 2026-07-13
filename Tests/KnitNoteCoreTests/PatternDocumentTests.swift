import Foundation
import Testing
@testable import KnitNoteCore

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

@MainActor @Test func storeWritesArchiveVersionFive() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Sweater")
    try store.addPattern(projectID: store.projects[0].id, pattern: PatternDocument(displayName: "Chart", kind: .image, storedFilename: "x.png"))
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("\"version\":5"))
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
    let expected=PatternReadingState(highlightEnabled:true,highlightPosition:0.2,highlightMode:.cross,verticalHighlightPosition:0.8)
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
    let expected=PatternReadingState(pageIndex:5,zoomScale:2.5,offsetX:0.3,offsetY:0.8,highlightEnabled:true,highlightPosition:0.66)
    try store.updatePatternState(projectID:projectID,id:pattern.id,state:expected)
    let actual=JSONProjectStore(url:url).projects[0].patterns[0].readingState
    #expect(actual == expected)
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

@Test func pdfReaderIgnoresOldPageSamplesUntilRequestedPageAppears() {
    var gate = PatternPDFPageRequestGate()
    gate.request(1)

    let acceptsOldPage = gate.shouldAcceptSample(0)
    #expect(!acceptsOldPage)
    #expect(gate.requestedPageIndex == 1)
    let acceptsRequestedPage = gate.shouldAcceptSample(1)
    #expect(acceptsRequestedPage)
    #expect(gate.requestedPageIndex == nil)
    let acceptsLaterPage = gate.shouldAcceptSample(2)
    #expect(acceptsLaterPage)
}

@Test func pdfRestorePageIsIndependentOfPageOffset() {
    let top = PatternReadingState(pageIndex: 2, offsetX: 0, offsetY: 0)
    let bottom = PatternReadingState(pageIndex: 2, offsetX: 1, offsetY: 1)

    #expect(top.pdfRestorePageIndex(pageCount: 8) == 2)
    #expect(bottom.pdfRestorePageIndex(pageCount: 8) == 2)
}

@Test func discretePDFPageMovementClampsAndClearsOffsets() {
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
    #expect(state.highlightPosition == 0.2)
    #expect(state.verticalHighlightPosition == 0.8)
    #expect(state.pageNote == "page two")
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
    var empty = try StoredProject(name: "Empty")
    var scarf = try StoredProject(name: "Scarf")
    let chart = PatternDocument(displayName: "Chart", kind: .pdf, storedFilename: "chart.pdf")
    scarf.addPattern(chart)

    let groups = patternGroups(from: [empty, scarf])

    #expect(groups.count == 1)
    #expect(groups[0].id == scarf.id)
    #expect(groups[0].projectName == "Scarf")
    #expect(groups[0].patterns == [chart])
}
