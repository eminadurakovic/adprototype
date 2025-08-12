
import SwiftUI

struct Packet: Decodable {
    let v: [Double]   // volts for A0..A3
}

@MainActor
final class WSModel: ObservableObject {
    @Published var values: [Double] = Array(repeating: .nan, count: 4)

    private var task: URLSessionWebSocketTask?

    func connect() {
        guard let url = URL(string: "ws://192.168.4.1/ws") else { return }
        let session = URLSession(configuration: .default)
        task = session.webSocketTask(with: url)
        task?.resume()
        receiveLoop()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.connect() }
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let pkt = try? JSONDecoder().decode(Packet.self, from: data),
                   pkt.v.count == 4 {
                    DispatchQueue.main.async {
                        self.values = pkt.v
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
        HStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { ch in
                VStack(spacing: 6) {
                    Text("A\(ch)")
                        .font(.caption).bold()
                    Text(vm.values[ch].isNaN ? "—" : String(format: "%.4f V", vm.values[ch]))
                        .font(.system(.title3, design: .monospaced))
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary))
            }
        }
        .padding()
        .onAppear { vm.connect() }
        .onDisappear { vm.disconnect() }
    }
}
