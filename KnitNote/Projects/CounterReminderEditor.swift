import SwiftUI

struct CounterReminderEditor: View {
    private enum Mode: Hashable {
        case oneTime
        case repeating
    }

    @Environment(\.dismiss) private var dismiss
    @Binding var draft: CounterReminderDraft?
    let counterValue: Int
    @State private var mode: Mode
    @State private var targetText: String
    @State private var intervalText: String
    @State private var hasFiniteLimit: Bool
    @State private var limitText: String
    @State private var messageText: String

    init(draft: Binding<CounterReminderDraft?>, counterValue: Int) {
        _draft = draft
        self.counterValue = counterValue

        let nextValue = counterValue < .max ? counterValue + 1 : counterValue
        switch draft.wrappedValue {
        case let .oneTime(target, message):
            _mode = State(initialValue: .oneTime)
            _targetText = State(initialValue: String(target))
            _intervalText = State(initialValue: "1")
            _hasFiniteLimit = State(initialValue: false)
            _limitText = State(initialValue: "1")
            _messageText = State(initialValue: message ?? "")
        case let .repeating(interval, limit, message):
            _mode = State(initialValue: .repeating)
            _targetText = State(initialValue: String(nextValue))
            _intervalText = State(initialValue: String(interval))
            _hasFiniteLimit = State(initialValue: limit != nil)
            _limitText = State(initialValue: String(limit ?? 1))
            _messageText = State(initialValue: message ?? "")
        case nil:
            _mode = State(initialValue: .oneTime)
            _targetText = State(initialValue: String(nextValue))
            _intervalText = State(initialValue: "1")
            _hasFiniteLimit = State(initialValue: false)
            _limitText = State(initialValue: "1")
            _messageText = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("counter.reminder.mode", selection: $mode) {
                    Text("counter.reminder.mode.oneTime").tag(Mode.oneTime)
                    Text("counter.reminder.mode.repeating").tag(Mode.repeating)
                }
                .pickerStyle(.segmented)

                if mode == .oneTime {
                    TextField("counter.reminder.target", text: $targetText)
                        .monospacedDigit()
                } else {
                    TextField("counter.reminder.interval", text: $intervalText)
                        .monospacedDigit()
                    Toggle("counter.reminder.limit", isOn: $hasFiniteLimit)
                    if hasFiniteLimit {
                        TextField("counter.reminder.limit", text: $limitText)
                            .monospacedDigit()
                    }
                }

                TextField("counter.reminder.message", text: $messageText, axis: .vertical)
                    .lineLimit(2...4)

                if draft != nil {
                    Button("counter.reminder.stop", role: .destructive) {
                        draft = nil
                        dismiss()
                    }
                }
            }
            .navigationTitle("counter.reminder.edit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        guard let validDraft else { return }
                        draft = validDraft
                        dismiss()
                    }
                    .disabled(validDraft == nil)
                }
            }
        }
    }

    private var validDraft: CounterReminderDraft? {
        let trimmedMessage = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmedMessage.isEmpty ? nil : trimmedMessage

        switch mode {
        case .oneTime:
            guard let target = try? CounterValueInput.parse(targetText),
                  target > counterValue else { return nil }
            return .oneTime(target: target, message: message)
        case .repeating:
            guard let interval = try? CounterValueInput.parse(intervalText),
                  interval > 0,
                  !counterValue.addingReportingOverflow(interval).overflow else { return nil }
            if hasFiniteLimit {
                guard let limit = try? CounterValueInput.parse(limitText),
                      limit > 0 else { return nil }
                return .repeating(interval: interval, limit: limit, message: message)
            }
            return .repeating(interval: interval, limit: nil, message: message)
        }
    }
}
