import SwiftUI

#if os(iOS)
import UIKit

struct JournalActivityView: UIViewControllerRepresentable {
    let payload: JournalSharePayload
    let completion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [payload.fileURL, payload.text],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
import AppKit

enum JournalShareActivityOutcome: Equatable {
    case completed
    case cancelled
    case failed
}

/// AppKit requires `NSSharingServicePicker.show` to run from the originating
/// mouse-down event. A native button preserves that timing and remains a real,
/// keyboard- and accessibility-operable control in the SwiftUI hierarchy.
final class MacJournalShareMouseDownButton: NSButton {
    var shareAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityRole(.button)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        shareAction?()
    }

    override func keyDown(with event: NSEvent) {
        if isEnabled && (event.keyCode == 36 || event.keyCode == 49) {
            shareAction?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let shareAction else { return false }
        shareAction()
        return true
    }
}

struct JournalActivityView: NSViewRepresentable {
    typealias PickerPresenter = @MainActor (NSSharingServicePicker, NSView) -> Void

    let isEnabled: Bool
    let accessibilityLabel: String
    let preparePayload: @MainActor () throws -> JournalSharePayload
    let completion: @MainActor (JournalSharePayload?, JournalShareActivityOutcome) -> Void
    private let pickerPresenter: PickerPresenter

    init(
        isEnabled: Bool,
        accessibilityLabel: String,
        preparePayload: @escaping @MainActor () throws -> JournalSharePayload,
        completion: @escaping @MainActor (JournalSharePayload?, JournalShareActivityOutcome) -> Void,
        pickerPresenter: @escaping PickerPresenter = Self.showPicker
    ) {
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.preparePayload = preparePayload
        self.completion = completion
        self.pickerPresenter = pickerPresenter
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            preparePayload: preparePayload,
            completion: completion,
            pickerPresenter: pickerPresenter
        )
    }

    func makeNSView(context: Context) -> MacJournalShareMouseDownButton {
        let button = MacJournalShareMouseDownButton()
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setAccessibilityIdentifier("journalShare.share")
        return button
    }

    func updateNSView(_ button: MacJournalShareMouseDownButton, context: Context) {
        button.title = accessibilityLabel
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(accessibilityLabel)
        button.shareAction = { [weak button, weak coordinator = context.coordinator] in
            guard isEnabled, let button, let coordinator else { return }
            coordinator.present(from: button)
        }
    }

    static func dismantleNSView(_ button: MacJournalShareMouseDownButton, coordinator: Coordinator) {
        button.shareAction = nil
        coordinator.cancelActiveShare()
    }

    @MainActor
    private static func showPicker(_ picker: NSSharingServicePicker, from view: NSView) {
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        private let preparePayload: () throws -> JournalSharePayload
        private let completion: (JournalSharePayload?, JournalShareActivityOutcome) -> Void
        private let pickerPresenter: PickerPresenter
        private var activePayload: JournalSharePayload?
        private var picker: NSSharingServicePicker?
        private var activeService: NSSharingService?
        private var operationRetainer: Coordinator?

        init(
            preparePayload: @escaping () throws -> JournalSharePayload,
            completion: @escaping (JournalSharePayload?, JournalShareActivityOutcome) -> Void,
            pickerPresenter: @escaping PickerPresenter
        ) {
            self.preparePayload = preparePayload
            self.completion = completion
            self.pickerPresenter = pickerPresenter
        }

        func present(from view: NSView) {
            guard activePayload == nil else { return }
            do {
                let payload = try preparePayload()
                activePayload = payload
                let picker = NSSharingServicePicker(items: MacJournalSharingItems.items(for: payload))
                picker.delegate = self
                self.picker = picker
                pickerPresenter(picker, view)
            } catch {
                completion(nil, .failed)
            }
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose service: NSSharingService?
        ) {
            guard let service else {
                finish(.cancelled)
                return
            }
            picker = nil
            service.delegate = self
            activeService = service
            // NSSharingService holds its delegate weakly. Keep this coordinator
            // alive if SwiftUI removes the button while the service reads the URL.
            operationRetainer = self
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            finish(.completed)
        }

        func sharingService(
            _ sharingService: NSSharingService,
            didFailToShareItems items: [Any],
            error: any Error
        ) {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               cocoaError.code == NSUserCancelledError {
                finish(.cancelled)
            } else {
                finish(.failed)
            }
        }

        func cancelActiveShare() {
            guard activeService == nil else { return }
            picker?.close()
            finish(.cancelled)
        }

        private func finish(_ outcome: JournalShareActivityOutcome) {
            guard let payload = activePayload else { return }
            activePayload = nil
            picker = nil
            activeService = nil
            completion(payload, outcome)
            operationRetainer = nil
        }
    }
}
#endif
