import Foundation

public struct YarnLabelFieldParser: Sendable {
    public init() {}

    public func parse(_ observations: [YarnLabelObservation]) -> YarnLabelParseResult {
        var candidates: [YarnLabelCandidate] = []
        for observation in observations where isValid(observation) {
            candidates.append(contentsOf: parse(observation))
        }

        let collapsed = collapseDuplicates(candidates)
        let fieldsRequiringConfirmation = Set(
            YarnLabelField.allCases.filter { field in
                let fieldCandidates = collapsed.filter { $0.field == field }
                return fieldCandidates.count > 1 || fieldCandidates.contains { $0.confidence < 0.8 }
            }
        )
        return YarnLabelParseResult(
            allCandidates: collapsed,
            fieldsRequiringConfirmation: fieldsRequiringConfirmation
        )
    }

    private func isValid(_ observation: YarnLabelObservation) -> Bool {
        let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && observation.confidence.isFinite &&
            (0...1).contains(observation.confidence) && (0...1).contains(observation.sourceImageIndex)
    }

    private func parse(_ observation: YarnLabelObservation) -> [YarnLabelCandidate] {
        let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [YarnLabelCandidate] = []

        if let value = capturedValue(
            in: text,
            pattern: #"^(?:brand|\u54c1\u724c)\s*[:\uff1a]?\s*(.+)$"#
        ) {
            result.append(candidate(.brand, value, observation))
        }
        if let value = capturedValue(
            in: text,
            pattern: #"^(?:series|range|\u7cfb\u5217)\s*[:\uff1a]?\s*(.+)$"#
        ) {
            result.append(candidate(.series, value, observation))
        }
        if let value = capturedValue(
            in: text,
            pattern: #"^(?:color\s*name|colour\s*name|\u8272\u540d)\s*[:\uff1a]?\s*(.+)$"#
        ) {
            result.append(candidate(.color, value, observation))
        } else if let value = capturedValue(
            in: text,
            pattern: #"^(?:color|colour|color\s*(?:no\.?|number)|colour\s*(?:no\.?|number)|\u8272\u865f)\s*[:#\uff1a]?\s*([\p{L}\p{N}._-]+)$"#
        ) {
            result.append(candidate(.colorCode, value, observation))
        }
        if let value = capturedValue(
            in: text,
            pattern: #"^(?:dye\s*lot|lot|\u67d3\u7f38\u865f)\s*[:#\uff1a]?\s*([\p{L}\p{N}._-]+)$"#
        ) {
            result.append(candidate(.dyeLot, value, observation))
        }

        if let range = metricRange(in: text, headingPattern: #"(?:needles?|knitting\s*needles?|\u68d2\u91dd|\u91dd\u865f)"#) {
            result.append(candidate(.recommendedNeedleMM, range.text, observation, metricRange: range.value))
        }
        if let range = metricRange(in: text, headingPattern: #"(?:hooks?|crochet\s*hooks?|\u9264\u91dd)"#) {
            result.append(candidate(.recommendedHookMM, range.text, observation, metricRange: range.value))
        }

        if let weight = measurement(
            in: text,
            pattern: #"([0-9]+(?:[.,][0-9]+)?)\s*(g|grams?|oz|ounces?)\b"#,
            metricMultiplier: 1,
            imperialMultiplier: Decimal(string: "28.349523125")!,
            metricUnits: ["g", "gram", "grams"]
        ) {
            result.append(candidate(.ballWeightGrams, decimalText(weight), observation, decimal: weight))
        }
        if let length = measurement(
            in: text,
            pattern: #"([0-9]+(?:[.,][0-9]+)?)\s*(m|meters?|metres?|yds?|yards?)\b"#,
            metricMultiplier: 1,
            imperialMultiplier: Decimal(string: "0.9144")!,
            metricUnits: ["m", "meter", "meters", "metre", "metres"]
        ) {
            result.append(candidate(.lengthMeters, decimalText(length), observation, decimal: length))
        }

        if isFiberContent(text) {
            result.append(candidate(.fiberContent, text, observation))
        }

        if result.isEmpty, let identity = uppercaseIdentity(text) {
            result.append(candidate(.brand, identity.brand, observation))
            if let series = identity.series {
                result.append(candidate(.series, series, observation))
            }
        }
        return result
    }

    private func candidate(
        _ field: YarnLabelField,
        _ text: String,
        _ observation: YarnLabelObservation,
        decimal: Decimal? = nil,
        metricRange: YarnMetricRange? = nil
    ) -> YarnLabelCandidate {
        YarnLabelCandidate(
            field: field,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            decimalValue: decimal,
            metricRangeValue: metricRange,
            confidence: observation.confidence,
            sourceImageIndex: observation.sourceImageIndex
        )
    }

    private func capturedValue(in text: String, pattern: String) -> String? {
        guard let groups = captureGroups(in: text, pattern: pattern), groups.count > 1 else { return nil }
        let value = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func metricRange(in text: String, headingPattern: String) -> (text: String, value: YarnMetricRange)? {
        let pattern = #"^"# + headingPattern + #"\s*[:\uff1a]?\s*([0-9]+(?:[.,][0-9]+)?)(?:\s*[-\u2013\u2014~\u81f3]\s*([0-9]+(?:[.,][0-9]+)?))?\s*mm\b"#
        guard let groups = captureGroups(in: text, pattern: pattern),
              groups.count > 2,
              let lower = decimal(groups[1]) else {
            return nil
        }
        let upper = decimal(groups[2]) ?? lower
        guard let range = try? YarnMetricRange(lower: lower, upper: upper) else { return nil }
        let display = lower == upper
            ? "\(decimalText(lower)) mm"
            : "\(decimalText(lower))–\(decimalText(upper)) mm"
        return (display, range)
    }

    private func measurement(
        in text: String,
        pattern: String,
        metricMultiplier: Decimal,
        imperialMultiplier: Decimal,
        metricUnits: Set<String>
    ) -> Decimal? {
        guard let groups = captureGroups(in: text, pattern: pattern), groups.count > 2,
              let value = decimal(groups[1]) else {
            return nil
        }
        let unit = groups[2].lowercased()
        let converted = value * (metricUnits.contains(unit) ? metricMultiplier : imperialMultiplier)
        return metricUnits.contains(unit) ? converted : rounded(converted, scale: 1)
    }

    private func decimal(_ text: String) -> Decimal? {
        Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
    }

    private func rounded(_ value: Decimal, scale: Int) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, .plain)
        return result
    }

    private func decimalText(_ value: Decimal) -> String {
        var value = value
        return NSDecimalString(&value, Locale(identifier: "en_US_POSIX") as NSLocale)
    }

    private func isFiberContent(_ text: String) -> Bool {
        guard text.range(of: #"\d+(?:[.,]\d+)?\s*%\s*\p{L}"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return false
        }
        return text.range(of: #"\b(?:g|grams?|m|meters?|yds?|yards?|mm)\b"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    private func uppercaseIdentity(_ text: String) -> (brand: String, series: String?)? {
        guard text.range(of: #"^[\p{Lu}][\p{Lu}\p{N}&.'-]*(?:\s+[\p{Lu}][\p{Lu}\p{N}&.'-]*)+$"#, options: .regularExpression) != nil else {
            return nil
        }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let brand = words.first else { return nil }
        let series = words.dropFirst().joined(separator: " ")
        return (brand, series.isEmpty ? nil : series)
    }

    private func captureGroups(in text: String, pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }

    private func collapseDuplicates(_ candidates: [YarnLabelCandidate]) -> [YarnLabelCandidate] {
        var bestByKey: [CandidateKey: YarnLabelCandidate] = [:]
        for candidate in candidates {
            let key = CandidateKey(candidate)
            if bestByKey[key].map({ $0.confidence < candidate.confidence }) != false {
                bestByKey[key] = candidate
            }
        }
        return bestByKey.values.sorted {
            if $0.field.rawValue != $1.field.rawValue { return $0.field.rawValue < $1.field.rawValue }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.text.localizedStandardCompare($1.text) == .orderedAscending
        }
    }
}

private struct CandidateKey: Hashable {
    let field: YarnLabelField
    let normalizedText: String
    let decimalValue: Decimal?
    let lower: Decimal?
    let upper: Decimal?

    init(_ candidate: YarnLabelCandidate) {
        field = candidate.field
        normalizedText = candidate.text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[\s:：#]+"#, with: "", options: .regularExpression)
        decimalValue = candidate.decimalValue
        lower = candidate.metricRangeValue?.lower
        upper = candidate.metricRangeValue?.upper
    }
}
