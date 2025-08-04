import Foundation
import Combine

final class WebSocketManager: ObservableObject {
    @Published var raw: String = "-"
    @Published var received: String = "-"
    @Published var applied: String = "-"
    @Published var offset: Double = 0.0
    @Published var isConnected: Bool = false

    private var task: URLSessionWebSocketTask?

    func connect() {
        let url = URL(string: "ws://192.168.4.1/ws")!
        task = URLSession.shared.webSocketTask(with: url)
        task?.resume()
        isConnected = true
        listen()
    }

    func sendOffset() { send(dict: ["offset": offset]) }
    func apply()      { send(dict: ["apply": true]) }

    private func send(dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { err in
            if let err = err { print("WS send error:", err) }
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case let .string(text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async {
                        if let v = json["raw"] as? Double      { self.raw = String(format: "%.2f", v) }
                        if let v = json["received"] as? Double { self.received = String(format: "%.2f", v) }
                        if let v = json["applied"] as? Double  { self.applied = String(format: "%.2f", v) }
                    }
                }
            case .failure(let e):
                print("WS rx error:", e)
                DispatchQueue.main.async { self.isConnected = false }
            }
            self.listen() // keep listening
        }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        isConnected = false
    }
}
