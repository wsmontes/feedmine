import Network
import SwiftUI

@MainActor
@Observable
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.feedmine.network-monitor")

    private(set) var isConnected = true
    var wasDisconnected = false

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let connected = path.status == .satisfied
                if !connected {
                    self.wasDisconnected = true
                }
                self.isConnected = connected
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
