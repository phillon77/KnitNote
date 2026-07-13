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

@MainActor @Test func storeWritesArchiveVersionFour() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = JSONProjectStore(url: url)
    try store.add(name: "Sweater")
    try store.addPattern(projectID: store.projects[0].id, pattern: PatternDocument(displayName: "Chart", kind: .image, storedFilename: "x.png"))
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("\"version\":4"))
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

@Test func pdfRestorePageIsIndependentOfPageOffset() {
    let top = PatternReadingState(pageIndex: 2, offsetX: 0, offsetY: 0)
    let bottom = PatternReadingState(pageIndex: 2, offsetX: 1, offsetY: 1)

    #expect(top.pdfRestorePageIndex(pageCount: 8) == 2)
    #expect(bottom.pdfRestorePageIndex(pageCount: 8) == 2)
}

@Test func pdfAnchorUpdatesPageAndPointAsOneUnit() {
    var state = PatternReadingState(pageIndex: 1, offsetX: 0, offsetY: 0)

    state.setPDFAnchor(pageIndex: 3, offsetX: 0.25, offsetY: 0.7)

    #expect(state.pageIndex == 3)
    #expect(state.offsetX == 0.25)
    #expect(state.offsetY == 0.7)
}

@Test func pdfHighlightAnchorClampsAndPersists() throws {
    var project = try StoredProject(name:"Chart")
    let pattern=PatternDocument(displayName:"Chart",kind:.pdf,storedFilename:"chart.pdf")
    project.addPattern(pattern)
    let state=PatternReadingState(highlightEnabled:true,highlightPosition:0.3,highlightMode:.cross,verticalHighlightPosition:0.8,highlightPageIndex:-2)

    project.updatePatternState(id:pattern.id,state:state)

    #expect(project.patterns[0].highlightPageIndex == 0)
    #expect(project.patterns[0].readingState.highlightPageIndex == 0)
}
