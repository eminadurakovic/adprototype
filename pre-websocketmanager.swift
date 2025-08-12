import Foundation
import Combine

final class WebSocketManager: ObservableObject {
    // MARK: Published state
    @Published var raw: [String]      = ["–","–"]
    @Published var applied: [String]  = ["–","–"]
    @Published var received: [String] = ["–","–"]
    @Published var bias: [Double]     = [0.0, 0.0]   // only b[2]
    @Published var dynEnabled: Bool   = false

    private var task: URLSessionWebSocketTask?

    func connect() {
        let url = URL(string: "ws://192.168.4.1/ws")!
        task = URLSession.shared.webSocketTask(with: url)
        task?.resume()
        listen()
        sendDynamicConfig()  // init
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
    }

    /// Send dynamic config: {"dyn":{"enable":..., "b":[b0,b1]}}
    func sendDynamicConfig() {
        let dyn: [String: Any] = [
            "enable": dynEnabled,
            "b": bias
        ]
        send(["dyn": dyn])
    }

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str  = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(str)) { error in
            if let e = error { print("WS send error:", e) }
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
                        if let arr = json["raw"] as? [Double], arr.count == 2 {
                            self.raw = arr.map { String(format: "%.2f", $0) }
                        }
                        if let arr = json["applied"] as? [Double], arr.count == 2 {
                            self.applied = arr.map { String(format: "%.2f", $0) }
                        }
                        if let arr = json["received"] as? [Double], arr.count == 2 {
                            self.received = arr.map { String(format: "%.2f", $0) }
                        }
                    }
                }
            case .failure(let error):
                print("WS receive error:", error)
            }
            self.listen()
        }
    }
}
