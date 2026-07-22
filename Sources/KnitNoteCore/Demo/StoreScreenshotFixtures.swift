import Foundation

public enum StoreScreenshotLanguage: String, CaseIterable, Sendable {
    case zhHant = "zh-Hant"
    case en
}

public enum StoreScreenshotScene: String, CaseIterable, Sendable {
    case projects
    case counters
    case patternHighlight
    case patternCrossHighlight
    case patternMarkup
    case patternNotes
    case journal
    case yarn
    case calculators
}

public struct StoreScreenshotFixturePackage: Sendable {
    public let archive: ProjectArchive
    public let files: [String: Data]

    public func archiveData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    @discardableResult
    public func install(in baseDirectory: URL) throws -> URL {
        let root = baseDirectory.appending(path: "KnitNote", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try archiveData().write(to: root.appending(path: "projects-v1.json"), options: .atomic)
        for (relativePath, data) in files {
            let destination = root.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        }
        return baseDirectory
    }
}

public enum StoreScreenshotFixtures {
    private static let projectID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private static let secondProjectID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    private static let patternID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    private static let fixedDate = Date(timeIntervalSince1970: 1_767_225_600)

    public static func make(language: StoreScreenshotLanguage) throws -> StoreScreenshotFixturePackage {
        let copy = Copy(language: language)
        let counterIDs = (1...6).map {
            UUID(uuidString: String(format: "30000000-0000-4000-8000-%012d", $0))!
        }
        let rowNotes = [
            RowNotePayload(row: 24, text: copy.rowNoteOne, createdAt: fixedDate, updatedAt: fixedDate),
            RowNotePayload(row: 32, text: copy.rowNoteTwo, createdAt: fixedDate, updatedAt: fixedDate),
        ]
        let counters = zip(copy.counterNames, [38, 6, 12, 4, 18, 16]).enumerated().map { index, item in
            CounterPayload(
                id: counterIDs[index],
                defaultOrdinal: index + 1,
                customName: item.0,
                value: item.1,
                mutationRevision: UInt64(item.1),
                rowNotes: index == 0 ? rowNotes : []
            )
        }

        var pattern = PatternDocument(
            id: patternID,
            displayName: copy.patternName,
            kind: .pdf,
            storedFilename: "cloud-shawl.pdf",
            createdAt: fixedDate
        )
        pattern.pageIndex = 0
        pattern.highlightEnabled = true
        pattern.highlightPosition = 0.43
        pattern.highlightMode = .cross
        pattern.verticalHighlightPosition = 0.58
        pattern.pageStates = [
            0: PatternPageState(
                horizontalPosition: 0.43,
                verticalPosition: 0.58,
                note: copy.pageNote
            ),
            1: PatternPageState(horizontalPosition: 0.64, verticalPosition: 0.36),
        ]

        let journalEntries = try makeJournalEntries(copy: copy)
        let firstProjectPhoto = "cloud-shawl-project.jpg"
        let projectPayloads = [
            ProjectPayload(
                id: projectID,
                name: copy.firstProject,
                counters: counters,
                selectedCounterID: counterIDs[0],
                createdAt: fixedDate,
                updatedAt: fixedDate,
                patterns: [pattern],
                photoFilename: firstProjectPhoto,
                completedAt: nil,
                toolType: .knittingNeedles,
                toolSize: "4.0 mm",
                toolNotes: copy.toolNote,
                journalEntries: journalEntries
            ),
            ProjectPayload(
                id: secondProjectID,
                name: copy.secondProject,
                counters: zip(counterIDs, [14, 3, 8, 2, 0, 0]).enumerated().map { index, item in
                    CounterPayload(
                        id: UUID(uuidString: item.0.uuidString.replacingOccurrences(of: "30000000", with: "31000000"))!,
                        defaultOrdinal: index + 1,
                        customName: copy.counterNames[index],
                        value: item.1,
                        mutationRevision: UInt64(item.1),
                        rowNotes: []
                    )
                },
                selectedCounterID: UUID(uuidString: counterIDs[0].uuidString.replacingOccurrences(of: "30000000", with: "31000000"))!,
                createdAt: fixedDate,
                updatedAt: fixedDate,
                patterns: [],
                photoFilename: nil,
                completedAt: nil,
                toolType: .crochetHook,
                toolSize: "3.5 mm",
                toolNotes: nil,
                journalEntries: []
            ),
        ]

        let yarns = try makeYarns(copy: copy)
        let payload = ArchivePayload(
            version: ProjectArchive.currentVersion,
            projects: projectPayloads,
            yarns: yarns
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: encoder.encode(payload))

        let swatch = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAABwElEQVR42u2ZMWrDQBBFdxUfw1XS5AjGTapcICcIOYiP4srkEi7cCR/BEGxcqDEYAmnUplBwlEg73zAsLvZNZayHikFC+3jxdGwDk56KFbAgFpRzJuvl9vltNnptvdxefhfLxNViM0T7t+hPgczvgjpuXzeHXWM8cqUx8XRseV4Mpkq9h//+vH+clslc9RXb102xTLycpLvPWfceju41hHDYNaUxcagaqb0+zKcFMjHlYn20f4vSmIisohosKKuLYV42w0laMH9cDPMaMti8YO5enl5HXs42fJ6/bIsphKkwL5uJq8UG8zKYWL9/YF4G86MamFeKwcVQDRaU18XoYjbDSVowdDHBYPN0MR9DFxNDFxMMXYwu5mNwMVSDBeV1Mcwr0MU8DF1MMNi8YOhidDEfQxeji/kYuhhdDNVgQTd1MbqYzXCSFgxdTDDYPF3Mx9DFxNDFBEMXo4v5GFwM1WBBeV0M8wp0MQ9DFxMMNi8YuhhdzMfQxehiPoYuRhdDNVjQTV2MLmYznKQFQxcTDDZPF/MxdDExdDHB0MXoYj4GF0M1WFBeF8O8Al3Mw9DFBIPNC4YuRhfzMXQxupiP+QZOcitNavVs2gAAAABJRU5ErkJggg==")!
        var files: [String: Data] = [
            "ProjectPhotos/\(firstProjectPhoto)": swatch,
            "Patterns/\(projectID.uuidString)/\(pattern.storedFilename)": makePatternPDF(),
        ]
        var markup = PatternMarkupDocument()
        markup.append(
            PatternMarkupStroke(
                points: [
                    .init(x: 0.26, y: 0.34),
                    .init(x: 0.34, y: 0.29),
                    .init(x: 0.43, y: 0.36),
                    .init(x: 0.36, y: 0.43),
                    .init(x: 0.26, y: 0.34),
                ],
                color: .red,
                width: 0.008
            )
        )
        let markupEncoder = JSONEncoder()
        markupEncoder.outputFormatting = [.sortedKeys]
        files[
            "Patterns/\(projectID.uuidString)/Markup/\(patternID.uuidString)/0.json"
        ] = try markupEncoder.encode(markup)
        for entry in journalEntries {
            files["ProjectJournalPhotos/\(entry.photoFilename)"] = swatch
            files["ProjectJournalPhotos/\(entry.thumbnailFilename)"] = swatch
        }
        for yarn in yarns {
            if let filename = yarn.photoFilename {
                files["YarnPhotos/\(filename)"] = swatch
            }
        }
        return StoreScreenshotFixturePackage(archive: archive, files: files)
    }

    private static func makeJournalEntries(copy: Copy) throws -> [ProjectJournalEntry] {
        let ids = [
            UUID(uuidString: "40000000-0000-4000-8000-000000000001")!,
            UUID(uuidString: "40000000-0000-4000-8000-000000000002")!,
        ]
        let token = UUID(uuidString: "41000000-0000-4000-8000-000000000001")!
        return try zip(ids, copy.journalCaptions).enumerated().map { index, item in
            let stem = "\(projectID.uuidString)-\(item.0.uuidString)-\(token.uuidString)"
            return try ProjectJournalEntry(
                id: item.0,
                photoFilename: "\(stem)-full.jpg",
                thumbnailFilename: "\(stem)-thumb.jpg",
                caption: item.1,
                createdAt: fixedDate.addingTimeInterval(Double(index) * 86_400)
            )
        }
    }

    private static func makeYarns(copy: Copy) throws -> [StoredYarn] {
        try copy.yarns.enumerated().map { index, values in
            let id = UUID(uuidString: String(format: "50000000-0000-4000-8000-%012d", index + 1))!
            var yarn = try StoredYarn(id: id, name: values.name, now: fixedDate)
            try yarn.updateInventory(balls: Decimal(values.balls), grams: Decimal(values.grams), now: fixedDate)
            try yarn.updateDetails(
                brand: values.brand,
                series: values.series,
                color: values.color,
                colorCode: values.code,
                dyeLot: "2026-A",
                storageLocation: values.location,
                notes: nil,
                now: fixedDate
            )
            yarn.setPhotoFilename("yarn-\(index + 1).jpg", now: fixedDate)
            return yarn
        }
    }

    private static func makePatternPDF() -> Data {
        let pageOne = "BT /F1 24 Tf 72 730 Td (1) Tj /F1 13 Tf 0 -42 Td (1 - 24) Tj 0 -30 Td (25 - 40) Tj 0 -45 Td (+  o  +  o  +  o  +  o) Tj 0 -24 Td (o  +  o  +  o  +  o  +) Tj ET"
        let pageTwo = "BT /F1 24 Tf 72 730 Td (2) Tj /F1 13 Tf 0 -42 Td (20 - 10) Tj 0 -30 Td (+  +  o  +  +  o  +  +) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(pageOne.utf8.count) >>\nstream\n\(pageOne)\nendstream",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>",
            "<< /Length \(pageTwo.utf8.count) >>\nstream\n\(pageTwo)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}

private struct ArchivePayload: Encodable {
    let version: Int
    let projects: [ProjectPayload]
    let yarns: [StoredYarn]
}

private struct ProjectPayload: Encodable {
    let id: UUID
    let name: String
    let counters: [CounterPayload]
    let selectedCounterID: UUID
    let createdAt: Date
    let updatedAt: Date
    let patterns: [PatternDocument]
    let photoFilename: String?
    let completedAt: Date?
    let toolType: ProjectToolType?
    let toolSize: String?
    let toolNotes: String?
    let journalEntries: [ProjectJournalEntry]
}

private struct CounterPayload: Encodable {
    let id: UUID
    let defaultOrdinal: Int
    let customName: String?
    let value: Int
    let mutationRevision: UInt64
    let rowNotes: [RowNotePayload]
}

private struct RowNotePayload: Encodable {
    let row: Int
    let text: String
    let createdAt: Date
    let updatedAt: Date
}

private struct Copy {
    struct YarnCopy {
        let name: String
        let brand: String
        let series: String
        let color: String
        let code: String
        let balls: Int
        let grams: Int
        let location: String
    }

    let firstProject: String
    let secondProject: String
    let counterNames: [String]
    let patternName: String
    let pageNote: String
    let rowNoteOne: String
    let rowNoteTwo: String
    let toolNote: String
    let journalCaptions: [String]
    let yarns: [YarnCopy]

    init(language: StoreScreenshotLanguage) {
        switch language {
        case .zhHant:
            firstProject = "雲朵披肩"
            secondProject = "小熊背心"
            counterNames = ["排數", "花樣重複", "袖窿", "領口", "左袖", "右袖"]
            patternName = "雲朵披肩織圖"
            pageNote = "第 24 排完成後開始領口減針"
            rowNoteOne = "換成薰衣草色毛線"
            rowNoteTwo = "下一排開始花樣重複"
            toolNote = "環形針 80 cm"
            journalCaptions = ["完成第一段花樣", "領口形狀完成"]
            yarns = [
                .init(name: "雲霧羊毛", brand: "KnitNote", series: "Soft Cloud", color: "薰衣草紫", code: "L08", balls: 4, grams: 180, location: "透明收納盒 A",),
                .init(name: "奶油棉線", brand: "KnitNote", series: "Daily Cotton", color: "奶油白", code: "C01", balls: 3, grams: 145, location: "書房第二層"),
                .init(name: "莓果混紡", brand: "KnitNote", series: "Berry Blend", color: "莓果紅", code: "B12", balls: 2, grams: 92, location: "編織袋"),
            ]
        case .en:
            firstProject = "Cloud Shawl"
            secondProject = "Little Bear Vest"
            counterNames = ["Rows", "Pattern Repeat", "Armhole", "Neckline", "Left Sleeve", "Right Sleeve"]
            patternName = "Cloud Shawl Pattern"
            pageNote = "Begin neckline decreases after row 24"
            rowNoteOne = "Change to lavender yarn"
            rowNoteTwo = "Begin pattern repeat on next row"
            toolNote = "80 cm circular needle"
            journalCaptions = ["First pattern section complete", "Neckline shaping complete"]
            yarns = [
                .init(name: "Cloud Wool", brand: "KnitNote", series: "Soft Cloud", color: "Lavender", code: "L08", balls: 4, grams: 180, location: "Clear box A"),
                .init(name: "Cream Cotton", brand: "KnitNote", series: "Daily Cotton", color: "Cream", code: "C01", balls: 3, grams: 145, location: "Studio shelf"),
                .init(name: "Berry Blend", brand: "KnitNote", series: "Berry Blend", color: "Berry", code: "B12", balls: 2, grams: 92, location: "Knitting bag"),
            ]
        }
    }
}
