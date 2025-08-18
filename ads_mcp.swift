
import SwiftUI

struct Packet: Decodable {
    let type: String?
    let v: [Double]?
    let ads: String?
    let dac: String?
}

@MainActor
final class WSModel: ObservableObject {
    @Published var values: [Double] = Array(repeating: .nan, count: 4)
    @Published var status: String = "Connecting…"

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?

    func connect() {
        guard let url = URL(string: "ws://192.168.4.1/ws") else { return }
        session = URLSession(configuration: .default)
        task = session?.webSocketTask(with: url)
        task?.resume()
        status = "Connecting…"
        startPings()
        receiveLoop()
    }

    func disconnect() {
        stopPings()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        status = "Disconnected"
    }

    private func startPings() {
        stopPings()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.task?.sendPing { _ in }
        }
    }

    private func stopPings() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                Task { @MainActor in
                    self.status = "Reconnecting…"
                    self.values = Array(repeating: .nan, count: 4)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.connect() }

            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let pkt = try? JSONDecoder().decode(Packet.self, from: data) {

                    Task { @MainActor in
                        if (pkt.type == "ads" || pkt.type == nil), let v = pkt.v, v.count == 4 {
                            self.values = v
                            if self.status == "Connecting…" || self.status.hasPrefix("Reconnecting") {
                                self.status = "Receiving"
                            }
                        } else if pkt.type == "status" {
                            self.status = "ADS: \(pkt.ads ?? "?"), DAC: \(pkt.dac ?? "?")"
                        }
                    }
                }
                self.receiveLoop()
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = WSModel()

    var body: some View {
        VStack(spacing: 16) {
            Text(vm.status)
                .font(.headline)
                .foregroundStyle(.blue)

            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { ch in
                    VStack(spacing: 6) {
                        Text("A\(ch)")
                            .font(.caption).bold()
                        Text(vm.values[ch].isNaN
                             ? "—"
                             : String(format: "%.4f V", vm.values[ch]))
                        .font(.system(.title3, design: .monospaced))
                        .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary))
                }
            }
        }
        .padding()
        .onAppear { vm.connect() }
        .onDisappear { vm.disconnect() }
    }
}
