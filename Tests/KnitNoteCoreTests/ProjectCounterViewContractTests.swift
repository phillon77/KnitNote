import Foundation
import Testing

@Suite struct ProjectCounterViewContractTests {
    @Test func projectDetailUsesCompactTapAndLongPressCounterControls() throws {
        let source = try projectSource(named: "ProjectDetailView")

        #expect(source.contains("CounterSelectorGrid("))
        #expect(source.contains("onIncrement:"))
        #expect(source.contains("onManage:"))
        #expect(!source.contains("project.completeRow"))
        #expect(!source.contains("project.undo"))
    }

    @Test func projectDetailPlacesNotesBeforeCounters() throws {
        let source = try projectSource(named: "ProjectDetailView")
        let counters = try #require(source.range(of: "CounterSelectorGrid("))
        let notes = try #require(source.range(of: "projectActionCard(\"notes.edit\""))

        #expect(notes.lowerBound < counters.lowerBound)
    }

    @Test func projectDetailShowsPhotoOrDefaultIconBeforeCounters() throws {
        let source = try projectSource(named: "ProjectDetailView")
        let photo = try #require(source.range(of: "ProjectCoverView(project: project)"))
        let counters = try #require(source.range(of: "CounterSelectorGrid("))

        #expect(photo.lowerBound < counters.lowerBound)
        #expect(source.contains(".frame(width: 96, height: 96)"))
        #expect(source.contains(".clipShape(.rect(cornerRadius: 22))"))
    }

    @Test func projectDetailRoutesNotesThroughCompositeCounterRowSelections() throws {
        let source = try projectSource(named: "ProjectDetailView")

        #expect(source.contains("CounterRowSelection("))
        #expect(source.contains("counterID: project.selectedCounterID"))
        #expect(source.contains("row: project.selectedCounter.value"))
        #expect(source.contains("AllNotesView(projectID: projectID, counterID: project.selectedCounterID)"))
        #expect(source.contains("counterID: selection.counterID"))
        #expect(source.contains("row: selection.row"))
    }

    @Test func noteViewsUseCounterScopedStoreAPIs() throws {
        let editSource = try projectSource(named: "EditRowNoteView")
        let notesSource = try projectSource(named: "AllNotesView")

        #expect(editSource.contains("let counterID: UUID"))
        #expect(editSource.contains("store.saveNote(projectID: projectID, counterID: counterID, row: row, text: text)"))
        #expect(editSource.contains("note(counterID: counterID, row: row)"))
        #expect(notesSource.contains("let counterID: UUID"))
        #expect(notesSource.contains("selectedCounter.rowNotes.sorted { $0.row > $1.row }"))
        #expect(notesSource.contains("store.deleteNote(projectID: projectID, counterID: counterID, row: note.row)"))
    }

    @Test func projectCardDoesNotShowCounterDetailsBelowTheProjectName() throws {
        let source = try projectSource(named: "ProjectCard")

        #expect(!source.contains("projectCounterDisplayName"))
        #expect(!source.contains("project.selectedCounter.value"))
        #expect(!source.contains("Text(\"project.currentRow\")"))
    }

    @Test func selectorShowsFullNamesAndUsesTapAndLongPress() throws {
        let source = try projectSource(named: "CounterSelectorGrid")

        #expect(source.contains(".counterActionTouchTarget()"))
        #expect(source.contains("projectCounterDisplayName(counter, locale: locale)"))
        #expect(source.contains("onIncrement(counter.id)"))
        #expect(source.contains("onLongPressGesture"))
        #expect(source.contains("onManage(counter.id)"))
    }

    @Test func counterManagerKeepsValueEditingAndEssentialControlsVisible() throws {
        let source = try projectSource(named: "CounterManagerView")

        #expect(source.contains("TextField(\"counter.value\""))
        #expect(source.contains("ViewThatFits"))
        #expect(source.contains("Button(\"counter.reset\""))
        #expect(!source.contains(".presentationDetents([.medium])"))
    }

    @Test func counterManagerUsesCompactEqualWidthValueControlsWithFullAccessibilityLabels() throws {
        let source = try projectSource(named: "CounterManagerView")
        let decrement = try #require(sourceSection(
            source,
            from: "private var decrementButton:",
            to: "private var incrementButton:"
        ))
        let increment = try #require(sourceSection(
            source,
            from: "private var incrementButton:",
            to: "private var resetButton:"
        ))
        let reset = try #require(sourceSection(
            source,
            from: "private var resetButton:",
            to: "private var currentValue:"
        ))

        #expect(decrement.contains("adjustValue(by: -1)"))
        #expect(decrement.contains("Text(\"−1\")"))
        #expect(decrement.components(separatedBy: ".frame(minWidth: 52, minHeight: 44)").count - 1 == 1)
        #expect(decrement.contains(".disabled(currentValue == 0)"))
        #expect(decrement.contains(".accessibilityLabel(Text(\"counter.minusOne\"))"))

        #expect(increment.contains("adjustValue(by: 1)"))
        #expect(increment.contains("Text(\"+1\")"))
        #expect(increment.components(separatedBy: ".frame(minWidth: 52, minHeight: 44)").count - 1 == 1)
        #expect(increment.contains(".disabled(currentValue == .max)"))
        #expect(increment.contains(".accessibilityLabel(Text(\"counter.increment\"))"))

        #expect(reset.contains("Image(systemName: \"arrow.counterclockwise\")"))
        #expect(reset.contains("Text(\"0\")"))
        #expect(reset.components(separatedBy: ".frame(minWidth: 52, minHeight: 44)").count - 1 == 1)
        #expect(reset.contains("role: .destructive"))
        #expect(reset.contains("confirmingValueReset = true"))
        #expect(reset.contains(".accessibilityLabel(Text(\"counter.reset\"))"))
        #expect(source.components(separatedBy: ".frame(minWidth: 52, minHeight: 44)").count - 1 == 3)
    }

    @Test func counterManagerUsesExplicitPlatformSizingWithoutScrollDependentEssentials() throws {
        let source = try projectSource(named: "CounterManagerView")

        #expect(source.contains("private enum CounterManagerPresentationPolicy"))
        #expect(source.contains("static let iPadWidth: CGFloat = 720"))
        #expect(source.contains("static let iPadHeight: CGFloat = 560"))
        #expect(source.contains("UIDevice.current.userInterfaceIdiom == .pad"))
        #expect(source.contains("CounterManagerPresentationPolicy.iPadWidth"))
        #expect(source.contains("CounterManagerPresentationPolicy.iPhoneWidth"))
        #expect(source.contains("CounterManagerPresentationPolicy.macMinimumWidth"))
        #expect(!source.contains("ScrollView"))
    }

    @Test func counterManagerStacksFullWidthNameAndValueEditorsOnIPad() throws {
        let source = try projectSource(named: "CounterManagerView")
        let layout = try #require(sourceSection(
            source,
            from: "private var editorLayout:",
            to: "private var nameEditor:"
        ))

        #expect(layout.contains("if usesLargeIPadPresentation"))
        #expect(layout.contains("VStack(alignment: .leading, spacing: 20)"))
        #expect(layout.contains("nameEditor\n                valueEditor"))
        #expect(layout.contains("else {\n            ViewThatFits(in: .horizontal)"))
        #expect(source.contains("editorLayout\n            .padding()"))
    }

    @Test func counterManagerConfirmsResetAndKeepsOnlyMigratedSecondaryReminderEditing() throws {
        let source = try projectSource(named: "CounterManagerView")

        #expect(source.contains("@State private var confirmingValueReset = false"))
        #expect(source.contains(".confirmationDialog(\"counter.reset\""))
        #expect(source.contains("Text(\"counter.value.invalid\")"))
        #expect(source.contains("counter.id != mainCounterID"))
        #expect(source.contains("KnittingReminderEditorView(projectID: projectID, reminderID: reminderID)"))
        #expect(!source.contains("CounterReminderEdit"))
    }

    @Test func projectCounterManagerKeepsItsSheetOpenWithTheSelectedAppLanguageWhenTheStoreRejects() throws {
        let source = try projectSource(named: "ProjectDetailView")

        #expect(source.contains("guard let _ = try store.manageCounter("))
        #expect(source.contains("LocaleAwareText.string(\"counter.error.notSaved\", locale: locale)"))
        #expect(!source.contains("String(localized: \"counter.error.notSaved\")"))
        #expect(!source.contains("try store.updateCounter(projectID:"))
    }

    @Test func projectCounterManagerPersistsValueAndNameWithoutLegacyReminderCreation() throws {
        let source = try projectSource(named: "ProjectDetailView")

        #expect(source.contains("try store.manageCounter("))
        #expect(source.contains("projectID: projectID"))
        #expect(source.contains("counterID: counter.id"))
        #expect(source.contains("name: save.name"))
        #expect(source.contains("value: save.value"))
        #expect(source.contains("reminder: .unchanged"))
        #expect(!source.contains("try store.configureCounterReminder("))
    }

    @Test func projectDetailShowsSelectedPendingReminderBelowCounters() throws {
        let source = try projectSource(named: "ProjectDetailView")
        #expect(source.contains("KnittingReminderQueueCard(projectID: projectID, project: project)"))
        #expect(!source.contains("CounterReminderCard"))
    }

    @Test func sharedQueueCardOwnsReminderActionsAndProjectDetailHasNoLocalMutation() throws {
        let source = try projectSource(named: "ProjectDetailView")
        #expect(source.contains("KnittingReminderQueueCard"))
        #expect(!source.contains("completeCounterReminder"))
        #expect(!source.contains("stopCounterReminder"))
        #expect(!source.contains("project.knittingReminders ="))
    }

    @Test func rejectedDirectReminderSaveKeepsTheManagerOpen() throws {
        let detail = try projectSource(named: "ProjectDetailView")
        let manager = try projectSource(named: "CounterManagerView")
        let save = try #require(sourceSection(
            detail,
            from: "private func saveCounter(",
            to: "private var hasActivePatterns"
        ))

        #expect(save.contains("guard let _ = try store.manageCounter("))
        #expect(save.contains("return false"))
        #expect(manager.contains("if onSave(savedCounter) { dismiss() }"))
    }

    @Test func reminderAccessibilityKeepsLocalizedSemanticsActionsAndAdaptiveHeight() throws {
        let manager = try projectSource(named: "CounterManagerView")
        let card = try source("KnitNote/Projects/KnittingReminderQueueCard.swift")
        let watch = try source("KnitNoteWatch/ProjectCountersView.swift")

        #expect(manager.contains(".accessibilityLabel(Text(\"counter.value.edit\"))"))
        #expect(!manager.contains(".accessibilityLabel(Text(\"counter.value\"))"))
        #expect(manager.contains("KnittingReminderEditorView(projectID: projectID, reminderID: reminderID)"))
        #expect(!manager.contains("CounterReminderEdit"))

        #expect(card.contains("Text(verbatim: text)"))
        #expect(card.contains(".accessibilityHint(Text(\"knittingReminder.card.complete.hint\"))"))
        #expect(card.contains(".accessibilityHint(Text(\"knittingReminder.card.stop.hint\"))"))
        #expect(card.components(separatedBy: "frame(minWidth: 44, minHeight: 44)").count - 1 >= 3)
        #expect(card.contains("ViewThatFits(in: .horizontal)"))
        #expect(!card.contains(".frame(height:"))
        #expect(card.contains(".accessibilityValue"))

        let watchReminder = try #require(sourceSection(
            watch,
            from: "private func reminderConfirmation(",
            to: "private func activeCounterRow"
        ))
        #expect(watchReminder.contains(".accessibilityHint(Text(\"counter.reminder.complete.hint\"))"))
        #expect(watchReminder.contains(".accessibilityHint(Text(\"counter.reminder.stop.hint\"))"))
        #expect(watchReminder.components(separatedBy: ".frame(minHeight: 44)").count - 1 == 2)
        #expect(!watchReminder.contains(".frame(height:"))
        #expect(!watchReminder.contains(".lineLimit("))
        #expect(watchReminder.contains("Text(verbatim: message)"))
    }

    @Test func completionUIShowsStatusAndLocksProjectCounters() throws {
        let edit = try projectSource(named: "EditProjectView")
        let detail = try projectSource(named: "ProjectDetailView")
        let card = try projectSource(named: "ProjectCard")
        let selector = try projectSource(named: "CounterSelectorGrid")

        #expect(edit.contains("store.markCompleted(projectID: projectID)"))
        #expect(edit.contains("store.resumeProject(projectID: projectID)"))
        #expect(detail.contains("isEnabled: !project.isCompleted"))
        #expect(detail.contains("project.status.completed"))
        #expect(card.contains("project.isCompleted"))
        #expect(card.contains("project.status.completed"))
        #expect(selector.contains("let isEnabled: Bool"))
        #expect(selector.contains("guard isEnabled else { return }"))
    }

    @Test func projectEditorAndDetailSupportOptionalToolDetails() throws {
        let edit = try projectSource(named: "EditProjectView")
        let detail = try projectSource(named: "ProjectDetailView")

        #expect(edit.contains("Section(\"project.tool.section\")"))
        #expect(edit.contains("Picker(\"project.tool.type\""))
        #expect(edit.contains("TextField(\"project.tool.size\""))
        #expect(edit.contains("TextField(\"project.tool.notes\""))
        #expect(edit.contains("toolType: toolType"))
        #expect(edit.contains("toolSize: toolSize"))
        #expect(edit.contains("toolNotes: toolNotes"))
        #expect(detail.contains("hasToolDetails(project)"))
        #expect(detail.contains("Text(\"project.tool.section\")"))
        #expect(detail.contains("if let toolType = project.toolType"))
        #expect(detail.contains("if let toolSize = project.toolSize"))
        #expect(detail.contains("if let toolNotes = project.toolNotes"))
    }

    private var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func projectSource(named name: String) throws -> String {
        try source("KnitNote/Projects/\(name).swift")
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
    }

    private func sourceSection(_ source: String, from start: String, to end: String) -> String? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            return nil
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func executableSwiftTokens(in source: String) -> [String] {
        let characters = Array(source)
        var tokens: [String] = []
        var index = 0

        while index < characters.count {
            if characters[index].isWhitespace {
                index += 1
            } else if startsConditionalCompilationBlock(characters, at: index) {
                index = firstIndexAfterConditionalCompilationBlock(in: characters, from: index)
            } else if startsLineComment(characters, at: index) {
                index = firstIndexAfterLineComment(in: characters, from: index + 2)
            } else if startsBlockComment(characters, at: index) {
                index = firstIndexAfterBlockComment(in: characters, from: index + 2)
            } else if let hashCount = rawStringHashCount(characters, at: index) {
                index = firstIndexAfterRawStringLiteral(
                    in: characters,
                    from: index,
                    hashCount: hashCount
                )
            } else if characters[index] == "\"" {
                index = firstIndexAfterStringLiteral(in: characters, from: index)
            } else if isIdentifierStart(characters[index]) {
                let start = index
                index += 1
                while index < characters.count, isIdentifierContinuation(characters[index]) {
                    index += 1
                }
                tokens.append(String(characters[start..<index]))
            } else if "=!<>+-*/%&|?".contains(characters[index]) {
                let start = index
                index += 1
                while index < characters.count, "=!<>+-*/%&|?".contains(characters[index]) {
                    index += 1
                }
                tokens.append(String(characters[start..<index]))
            } else {
                tokens.append(String(characters[index]))
                index += 1
            }
        }

        return tokens
    }

    private func executableSection(
        _ tokens: [String],
        from start: String,
        to end: String
    ) -> [String]? {
        guard let startIndex = tokens.firstIndex(of: start),
              let endIndex = tokens[(startIndex + 1)...].firstIndex(of: end)
        else { return nil }
        return Array(tokens[startIndex..<endIndex])
    }

    private func executableFunction(named name: String, in tokens: [String]) -> [String]? {
        guard let startIndex = tokens.indices.first(where: {
            tokens[$0] == "func" && $0 + 1 < tokens.count && tokens[$0 + 1] == name
        }), let openingBrace = tokens[startIndex...].firstIndex(of: "{")
        else { return nil }

        var depth = 0
        for index in openingBrace..<tokens.count {
            switch tokens[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return Array(tokens[startIndex...index]) }
            default: break
            }
        }
        return nil
    }

    private func hasFailClosedPrecondition(
        in tokens: [String],
        requiresActiveReminder: Bool
    ) -> Bool {
        var expected = [
            "guard", "let", "currentProject", "=", "store", ".", "project", "(", "id", ":", "projectID", ")", ",",
            "currentProject", ".", "selectedCounterID", "==", "counterID", ",",
            "let", "currentCounter", "=", "currentProject", ".", "counters", ".", "first", "(", "where", ":", "{", "$0", ".", "id", "==", "counterID", "}", ")", ",",
            "currentCounter", ".", "id", "==", "counterID", ",",
            "let", "currentReminder", "=", "currentCounter", ".", "reminder", ",",
            "currentReminder", ".", "id", "==", "pending", ".", "reminderID", ",",
        ]
        if requiresActiveReminder {
            expected += ["currentReminder", ".", "isActive", "==", "true", ","]
        }
        expected += [
            "let", "currentPending", "=", "currentReminder", ".", "pending", ",",
            "currentPending", ".", "reminderID", "==", "pending", ".", "reminderID", ",",
            "currentPending", ".", "occurrenceCount", "==", "pending", ".", "occurrenceCount",
            "else", "{", "reminderActionFailed", "(", ")", "return", "}",
        ]
        return containsTokenSequence(tokens, expected)
    }

    private func hasFailClosedPostcondition(
        in tokens: [String],
        requiresInactiveReminder: Bool
    ) -> Bool {
        var expected = [
            "guard", "store", ".", "dataGeneration", ">", "dataGenerationBefore", ",",
            "let", "updatedProject", "=", "store", ".", "project", "(", "id", ":", "projectID", ")", ",",
            "updatedProject", ".", "selectedCounterID", "==", "counterID", ",",
            "let", "updatedCounter", "=", "updatedProject", ".", "counters", ".", "first", "(", "where", ":", "{", "$0", ".", "id", "==", "counterID", "}", ")", ",",
            "updatedCounter", ".", "id", "==", "counterID", ",",
            "let", "updatedReminder", "=", "updatedCounter", ".", "reminder", ",",
            "updatedReminder", ".", "id", "==", "pending", ".", "reminderID", ",",
            "updatedReminder", ".", "pending", "==", "nil",
        ]
        if requiresInactiveReminder {
            expected += [",", "updatedReminder", ".", "isActive", "!=", "true"]
        }
        expected += ["else", "{", "reminderActionFailed", "(", ")", "return", "}"]
        return containsTokenSequence(tokens, expected)
    }

    private func hasErrorRetention(in tokens: [String]) -> Bool {
        containsTokenSequence(tokens, [
            "catch", "{", "counterSaveError", "=", "error", ".", "localizedDescription", "}",
        ])
    }

    private func containsTokenSequence(_ tokens: [String], _ expected: [String]) -> Bool {
        tokenSequenceCount(tokens, matching: expected) > 0
    }

    private func tokenSequenceCount(_ tokens: [String], matching expected: [String]) -> Int {
        guard !expected.isEmpty, tokens.count >= expected.count else { return 0 }
        return (0...(tokens.count - expected.count)).reduce(into: 0) { count, index in
            if Array(tokens[index..<(index + expected.count)]) == expected {
                count += 1
            }
        }
    }

    private func startsLineComment(_ characters: [Character], at index: Int) -> Bool {
        index + 1 < characters.count && characters[index] == "/" && characters[index + 1] == "/"
    }

    private func startsBlockComment(_ characters: [Character], at index: Int) -> Bool {
        index + 1 < characters.count && characters[index] == "/" && characters[index + 1] == "*"
    }

    private func firstIndexAfterLineComment(in characters: [Character], from index: Int) -> Int {
        var index = index
        while index < characters.count, characters[index] != "\n" { index += 1 }
        return index
    }

    private func firstIndexAfterBlockComment(in characters: [Character], from index: Int) -> Int {
        var index = index
        var depth = 1
        while index < characters.count, depth > 0 {
            if startsBlockComment(characters, at: index) {
                depth += 1
                index += 2
            } else if index + 1 < characters.count, characters[index] == "*", characters[index + 1] == "/" {
                depth -= 1
                index += 2
            } else {
                index += 1
            }
        }
        return index
    }

    private func startsConditionalCompilationBlock(_ characters: [Character], at index: Int) -> Bool {
        guard characters[index] == "#", isAtLineDirectiveStart(characters, at: index) else {
            return false
        }
        let suffix = characters[index...]
        guard suffix.starts(with: Array("#if")) else { return false }
        let boundary = index + 3
        return boundary == characters.count || characters[boundary].isWhitespace
    }

    private func endsConditionalCompilationBlock(_ characters: [Character], at index: Int) -> Bool {
        guard characters[index] == "#", isAtLineDirectiveStart(characters, at: index) else {
            return false
        }
        let suffix = characters[index...]
        guard suffix.starts(with: Array("#endif")) else { return false }
        let boundary = index + 6
        return boundary == characters.count || characters[boundary].isWhitespace
    }

    private func isAtLineDirectiveStart(_ characters: [Character], at index: Int) -> Bool {
        var cursor = index
        while cursor > 0, characters[cursor - 1] != "\n" {
            guard characters[cursor - 1].isWhitespace else { return false }
            cursor -= 1
        }
        return true
    }

    private func firstIndexAfterConditionalCompilationBlock(
        in characters: [Character],
        from index: Int
    ) -> Int {
        var cursor = index
        var depth = 0
        while cursor < characters.count {
            if startsLineComment(characters, at: cursor) {
                cursor = firstIndexAfterLineComment(in: characters, from: cursor + 2)
            } else if startsBlockComment(characters, at: cursor) {
                cursor = firstIndexAfterBlockComment(in: characters, from: cursor + 2)
            } else if let hashCount = rawStringHashCount(characters, at: cursor) {
                cursor = firstIndexAfterRawStringLiteral(
                    in: characters,
                    from: cursor,
                    hashCount: hashCount
                )
            } else if characters[cursor] == "\"" {
                cursor = firstIndexAfterStringLiteral(in: characters, from: cursor)
            } else if startsConditionalCompilationBlock(characters, at: cursor) {
                depth += 1
                cursor = firstIndexAfterDirectiveLine(in: characters, from: cursor)
            } else if endsConditionalCompilationBlock(characters, at: cursor) {
                depth -= 1
                let nextLine = firstIndexAfterDirectiveLine(in: characters, from: cursor)
                if depth == 0 { return nextLine }
                cursor = nextLine
            } else {
                cursor += 1
            }
        }
        return cursor
    }

    private func firstIndexAfterDirectiveLine(in characters: [Character], from index: Int) -> Int {
        let lineEnd = characters[index...].firstIndex(of: "\n") ?? characters.endIndex
        return lineEnd < characters.endIndex ? lineEnd + 1 : lineEnd
    }

    private func rawStringHashCount(_ characters: [Character], at index: Int) -> Int? {
        guard characters[index] == "#" else { return nil }
        var cursor = index
        while cursor < characters.count, characters[cursor] == "#" { cursor += 1 }
        guard cursor < characters.count, characters[cursor] == "\"" else { return nil }
        return cursor - index
    }

    private func firstIndexAfterRawStringLiteral(
        in characters: [Character],
        from index: Int,
        hashCount: Int
    ) -> Int {
        let quoteIndex = index + hashCount
        let isMultiline = quoteIndex + 2 < characters.count
            && characters[quoteIndex + 1] == "\""
            && characters[quoteIndex + 2] == "\""
        let quoteCount = isMultiline ? 3 : 1
        var cursor = quoteIndex + quoteCount

        while cursor < characters.count {
            let hasQuotes = (0..<quoteCount).allSatisfy {
                cursor + $0 < characters.count && characters[cursor + $0] == "\""
            }
            let hashStart = cursor + quoteCount
            let hasHashes = hasQuotes && (0..<hashCount).allSatisfy {
                hashStart + $0 < characters.count && characters[hashStart + $0] == "#"
            }
            if hasQuotes, hasHashes { return hashStart + hashCount }
            cursor += 1
        }
        return cursor
    }

    private func firstIndexAfterStringLiteral(in characters: [Character], from index: Int) -> Int {
        let isMultiline = index + 2 < characters.count
            && characters[index + 1] == "\""
            && characters[index + 2] == "\""
        var index = index + (isMultiline ? 3 : 1)
        while index < characters.count {
            if isMultiline,
               index + 2 < characters.count,
               characters[index] == "\"",
               characters[index + 1] == "\"",
               characters[index + 2] == "\"",
               !isEscapedStringDelimiter(characters, at: index) {
                return index + 3
            }
            if !isMultiline, characters[index] == "\\" {
                index += 2
            } else if !isMultiline, characters[index] == "\"" {
                return index + 1
            } else {
                index += 1
            }
        }
        return index
    }

    private func isEscapedStringDelimiter(_ characters: [Character], at index: Int) -> Bool {
        var precedingBackslashes = 0
        var cursor = index
        while cursor > 0, characters[cursor - 1] == "\\" {
            precedingBackslashes += 1
            cursor -= 1
        }
        return precedingBackslashes.isMultiple(of: 2) == false
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    private func isIdentifierContinuation(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }
}
