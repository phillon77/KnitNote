import SwiftUI
import UIKit

@MainActor
final class ShareViewController: UIViewController {
    private var importController: ShareImportController?

    override func viewDidLoad() {
        super.viewDidLoad()
        let locale = LanguageSelectionProjection.live()?.resolvedLocale()
            ?? LanguageSettings(selection: .system).resolvedLocale()
        let importController = ShareImportController(
            extensionContext: extensionContext
        )
        self.importController = importController

        let host = UIHostingController(
            rootView: ShareImportView(controller: importController)
                .environment(\.locale, locale)
        )
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        importController?.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        importController?.cancelIfNeeded()
        super.viewDidDisappear(animated)
    }
}
