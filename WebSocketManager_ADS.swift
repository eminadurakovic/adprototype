
import Foundation
import Combine

final class WebSocketManager: ObservableObject {
    @Published var status: String = "Waiting..."
    private var task: URLSessionWebSocketTask?

    func connect() {
        guard let url = URL(string: "ws://192.168.4.1/ws") else { return }
        let session = URLSession(configuration: .default)
        task = session.webSocketTask(with: url)
        task?.resume()
        listen()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case let .string(text) = message {
                    DispatchQueue.main.async {
                        self.status = text
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    self.status = "Error: \(error.localizedDescription)"
                }
            }
            self.listen() // keep listening
        }
    }
}
