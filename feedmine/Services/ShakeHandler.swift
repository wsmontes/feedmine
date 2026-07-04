import SwiftUI

/// Detects device shake gesture and triggers a callback.
struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        ShakeViewController(onShake: onShake)
    }

    func updateUIViewController(_ uiViewController: ShakeViewController, context: Context) {}

    final class ShakeViewController: UIViewController {
        let onShake: () -> Void

        init(onShake: @escaping () -> Void) {
            self.onShake = onShake
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake { onShake() }
        }
    }
}
