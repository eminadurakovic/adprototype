import SwiftUI

// MARK: - Models

struct Packet: Decodable {
    let v: [Double]?       // final volts (after offset, clamped) - A0..A3
    let offs: [Double]?    // current offsets
    let mcp: [Double]?     // <-- NEW: MCP0..MCP3 raw/other source
    let type: String?
}

@MainActor
final class WSModel: ObservableObject {
    enum State { case idle, connecting, connected, retrying, failed }
    @Published var state: State = .idle
    @Published var values: [Double] = Array(repeating: .nan, count: 4)      // A0..A3
    @Published var offsets: [Double] = [0,0,0,0]
    @Published var mcpValues: [Double] = Array(repeating: .nan, count: 4)   // <-- NEW: MCP0..MCP3

    private var task: URLSessionWebSocketTask?
    private let url = URL(string: "ws://192.168.4.1/ws")!

    func connect() {
        guard task == nil else { return }
        state = .connecting
        let session = URLSession(configuration: .default)
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.state = .retrying
                self.task = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.connect() }
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let pkt = try? JSONDecoder().decode(Packet.self, from: data) {

                    // Accept packets regardless of declared type; update what’s present.
                    if let v = pkt.v, v.count == 4 { self.values = v }
                    if let o = pkt.offs, o.count == 4 { self.offsets = o }
                    if let m = pkt.mcp, m.count == 4 { self.mcpValues = m } // <-- NEW

                    if self.state != .connected { self.state = .connected }
                }
                self.receiveLoop()
            }
        }
    }

    func sendOffsets() {
        let dict: [String:Any] = ["cmd":"setOffset","v":offsets]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let str = String(data: data, encoding: .utf8) {
            task?.send(.string(str)) { if case .some(let e) = $0 { print("Send error:", e) } }
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var vm = WSModel()

    var body: some View {
        ZStack {
            AngularGradient(gradient: Gradient(colors: [.blue.opacity(0.25), .purple.opacity(0.25), .mint.opacity(0.25), .indigo.opacity(0.25)]),
                            center: .topLeading).ignoresSafeArea()

            mainUI
                .opacity(vm.state == .connected ? 1 : 0)

            if vm.state != .connected {
                SplashView(state: vm.state)
            }
        }
        .task { vm.connect() }
        .onDisappear { vm.disconnect() }
    }

    private var mainUI: some View {
        VStack(spacing: 25) {
            header

            // --- Row 1: ADS ---
            VStack(alignment: .leading, spacing: 10) {
                Text("ADS Voltages")
                    .font(.headline)
                    .padding(.leading, 4)

                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { ch in
                        ValueCard(label: "A\(ch)", value: vm.values[ch])
                    }
                }
            }

            // --- Row 2: MCP ---
            VStack(alignment: .leading, spacing: 10) {
                Text("MCP Voltages")
                    .font(.headline)
                    .padding(.leading, 4)

                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { ch in
                        ValueCard(label: "MCP\(ch)", value: vm.mcpValues[ch], compact: true)
                    }
                }
            }

            // Define your custom labels once
            let offsetLabels = ["Rear Right Wheel", "Rear Left Wheel", "Front Right Wheel", "Front Right Wheel"]

            // Offsets
            VStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { ch in
                    VStack(spacing: 8) {
                        HStack {
                            Label(offsetLabels[ch], systemImage: "plus.forwardslash.minus")
                            Spacer()
                            Text(String(format: "%.2f V", vm.offsets[ch]))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout.bold())

                        Slider(
                            value: Binding(
                                get: { vm.offsets[ch] },
                                set: { vm.offsets[ch] = $0; vm.sendOffsets() }
                            ),
                            in: -2.5...2.5, step: 0.01
                        )
                        .tint(.indigo)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
                }
            }


            Spacer(minLength: 8)
        }
        .padding(16)
    }


    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Monitor").font(.largeTitle.bold())
                Text("ADS A0–A3 · MCP0–MCP3 · Offsets")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            StatePill(state: vm.state)
        }
    }
}

// Reusable value card (works for A* and MCP*)
private struct ValueCard: View {
    let label: String
    let value: Double
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.caption).bold().opacity(0.7)
            Text(value.isNaN ? "—" : String(format: "%.3f V", value))
                .font(.system(size: compact ? 10 : 12, design: .monospaced)) // smaller digits
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 44 : 50)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15)))
        .shadow(radius: 6, y: 3)
    }
}

// MARK: - State pill & Splash (unchanged from your version)

struct StatePill: View {
    let state: WSModel.State
    var body: some View {
        let (text, system) = switch state {
        case .connected: ("Connected", "checkmark.circle.fill")
        case .connecting: ("Connecting…", "wave.3.right.circle.fill")
        case .retrying: ("Reconnecting…", "arrow.triangle.2.circlepath.circle.fill")
        case .failed: ("Failed", "xmark.octagon.fill")
        case .idle: ("Idle", "pause.circle.fill")
        }
        return Label(text, systemImage: system)
            .font(.footnote.bold())
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
    }
}

struct SplashView: View {
    let state: WSModel.State
    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(title).font(.title3.bold())
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            ProgressView().progressViewStyle(.circular).tint(.white)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(radius: 12)
        )
    }
    private var title: String {
        switch state {
        case .connecting: return "Connecting to device…"
        case .retrying:   return "Reconnecting…"
        case .failed:     return "Connection failed"
        case .idle:       return "Starting…"
        case .connected:  return "Ready"
        }
    }
    private var subtitle: String {
        switch state {
        case .connecting: return ""
        case .retrying:   return "We’ll try again in a moment"
        case .failed:     return "Check Wi-Fi/AP and try again"
        case .idle:       return "Preparing session"
        case .connected:  return "Receiving data"
        }
    }
}
