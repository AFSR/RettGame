import SwiftUI
import SafariServices

/// Représentable SwiftUI pour `SFSafariViewController` — ouvre une URL en
/// Safari embarqué (chrome minimal, lecteur, AutoFill), tout en restant dans
/// le processus de l'app.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = UIColor(Color.afsrPurpleAdaptive)
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
