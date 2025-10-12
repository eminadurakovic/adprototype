import SwiftUI

// MARK: - Models (accept both old & new packets)
struct Packet: Decodable {
    let v: [Double]?        // raw inputs A0..A3
    let offs: [Double]?     // per-channel offsets
    let mcp: [Double]?      // actual outputs from device (preferred, if present)
    let vout: [Double]?     // alias some firmware might use
    let type: String?
}

@MainActor
final class WSModel: ObservableObject {
    enum State { case idle, connecting, connected, retrying, failed }

    // Offset control modes
    enum OffsetMode: String, CaseIterable, Identifiable {
        case individual = "Per wheel"
        case all = "All wheels"
        case frontRear = "Front vs Rear"
        var id: String { rawValue }
    }

    @Published var state: State = .idle

    // Inputs from ESP (A0..A3)
    @Published var values: [Double] = Array(repeating: .nan, count: 4)

    // Offsets we actually apply/send (always 4-length).
    @Published var offsets: [Double] = [0,0,0,0] {
        didSet { recomputeOutputsIfNeeded() }
    }

    // Mode & backing stores
    @Published var mode: OffsetMode = .individual {
        didSet { applyMode(shouldSend: true) }   // mode change can send immediately
    }
    @Published var perChannelOffsets: [Double] = [0,0,0,0] {
        didSet {
            if mode == .individual {
                offsets = perChannelOffsets     // local recompute only; do NOT send here
            }
        }
    }
    @Published var allOffset: Double = 0 {
        didSet { if mode == .all { applyMode(shouldSend: false) } }  // send on drag end only
    }
    @Published var frontOffset: Double = 0 {
        didSet { if mode == .frontRear { applyMode(shouldSend: false) } } // send on drag end only
    }
    @Published var rearOffset: Double = 0 {
        didSet { if mode == .frontRear { applyMode(shouldSend: false) } } // send on drag end only
    }

    // Shown outputs (what the DAC should drive)
    @Published var mcpValues: [Double] = Array(repeating: .nan, count: 4)

    // Tracks whether the latest packet included device outputs.
    private var lastHadDeviceOut = false

    private var task: URLSessionWebSocketTask?
    private let url = URL(string: "ws://192.168.4.1/ws")!

    // ---- UI/output clamp window (matches firmware): 0.5 … 4.5 V ----
    private let uiClampMin: Double = 0.5
    private let uiClampMax: Double = 4.5

    // ---- Offset slider range (±4 V) ----
    static let offsetMin: Double = -4.0
    static let offsetMax: Double =  4.0

    // ---- Simple echo guard while editing ----
    @Published var isEditingOffsets: Bool = false

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
                   let pkt = try? JSONDecoder().decode(Packet.self, from: data),
                   pkt.type == "ads" || pkt.v != nil || pkt.offs != nil {

                    if let v = pkt.v, v.count == 4 {
                        self.values = v
                    }

                    // Accept incoming offsets only if we are NOT currently dragging
                    if let o = pkt.offs, o.count == 4, !self.isEditingOffsets {
                        self.perChannelOffsets = o
                        self.applyMode(shouldSend: false) // recompute locally; no send
                    }

                    // Prefer device-reported outputs if present; otherwise compute locally.
                    if let devOut = (pkt.mcp ?? pkt.vout), devOut.count == 4 {
                        self.lastHadDeviceOut = true
                        self.mcpValues = devOut.map { min(max($0, self.uiClampMin), self.uiClampMax) }
                    } else {
                        self.lastHadDeviceOut = false
                        self.recomputeOutputs()
                    }

                    if self.state != .connected { self.state = .connected }
                }
                self.receiveLoop()
            }
        }
    }

    private func recomputeOutputs() {
        var out = [Double](repeating: .nan, count: 4)
        for i in 0..<4 {
            let vin = values.indices.contains(i) ? values[i] : .nan
            let off = offsets.indices.contains(i) ? offsets[i] : 0.0
            guard !vin.isNaN else { continue }
            let req = vin + off
            out[i] = min(max(req, uiClampMin), uiClampMax) // clamp 0.5…4.5 V
        }
        mcpValues = out
    }

    /// Only recompute if the device did NOT provide outputs in the last packet.
    private func recomputeOutputsIfNeeded() {
        if !lastHadDeviceOut { recomputeOutputs() }
    }

    // MARK: - Offsets: apply & (optionally) send
    fileprivate func applyMode(shouldSend: Bool = false) {
        switch mode {
        case .individual:
            offsets = perChannelOffsets
        case .all:
            offsets = [allOffset, allOffset, allOffset, allOffset]
        case .frontRear:
            // Index mapping: 0: RR, 1: RL, 2: FR, 3: FL
            offsets = [rearOffset, rearOffset, frontOffset, frontOffset]
        }
        if shouldSend { sendOffsets() }
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
            AngularGradient(
                gradient: Gradient(colors: [.blue.opacity(0.25), .purple.opacity(0.25), .mint.opacity(0.25), .indigo.opacity(0.25)]),
                center: .topLeading
            ).ignoresSafeArea()

            mainUI
        }
        .task { vm.connect() }
        .onDisappear { vm.disconnect() }
    }

    private var mainUI: some View {
        VStack(spacing: 25) {
            header

            // --- Row 1: ADS (Inputs) ---
            VStack(alignment: .leading, spacing: 10) {
                Text("Input Voltages")
                    .font(.headline)
                    .padding(.leading, 4)

                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { ch in
                        ValueCard(label: "A\(ch)", value: vm.values[ch])
                    }
                }
            }

            // --- Row 2: MCP (Outputs) ---
            VStack(alignment: .leading, spacing: 10) {
                Text("Output Voltages (0.5–4.5 V)")
                    .font(.headline)
                    .padding(.leading, 4)

                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { ch in
                        ValueCard(label: "MCP\(ch)", value: vm.mcpValues[ch], compact: true)
                    }
                }
            }

            let offsetLabels = ["Rear Right Wheel", "Rear Left Wheel", "Front Right Wheel", "Front Left Wheel"]

            // --- Offset Mode Picker ---
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Offset Mode", systemImage: "slider.horizontal.3")
                    Spacer()
                    Picker("Offset Mode", selection: $vm.mode) {
                        ForEach(WSModel.OffsetMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .font(.callout.bold())
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
            }

            // --- Offsets (vary by mode) ---
            switch vm.mode {
            case .individual:
                VStack(spacing: 14) {
                    ForEach(0..<4, id: \.self) { ch in
                        VStack(spacing: 8) {
                            HStack {
                                Label(offsetLabels[ch], systemImage: "plus.forwardslash.minus")
                                Spacer()
                                Text(String(format: "%.2f V", vm.perChannelOffsets[ch]))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout.bold())

                            HStack {
                                Slider(
                                    value: Binding(
                                        get: { vm.perChannelOffsets[ch] },
                                        set: { vm.perChannelOffsets[ch] = $0 }
                                    ),
                                    in: WSModel.offsetMin...WSModel.offsetMax,
                                    step: 0.01,
                                    onEditingChanged: { editing in
                                        vm.isEditingOffsets = editing
                                        if !editing {
                                            // Send once when dragging stops
                                            vm.applyMode(shouldSend: true)
                                        }
                                    }
                                )
                                .tint(.indigo)

                                Text("±4 V")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
                    }
                }

            case .all:
                VStack(spacing: 14) {
                    VStack(spacing: 8) {
                        HStack {
                            Label("All Wheels", systemImage: "plus.forwardslash.minus")
                            Spacer()
                            Text(String(format: "%.2f V", vm.allOffset))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout.bold())

                        HStack {
                            Slider(
                                value: Binding(
                                    get: { vm.allOffset },
                                    set: { vm.allOffset = $0 }
                                ),
                                in: WSModel.offsetMin...WSModel.offsetMax,
                                step: 0.01,
                                onEditingChanged: { editing in
                                    vm.isEditingOffsets = editing
                                    if !editing {
                                        vm.applyMode(shouldSend: true)
                                    }
                                }
                            )
                            .tint(.indigo)

                            Text("±4 V")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
                }

            case .frontRear:
                VStack(spacing: 14) {
                    // Rear group (indices 0,1)
                    VStack(spacing: 8) {
                        HStack {
                            Label("Rear (RR + RL)", systemImage: "plus.forwardslash.minus")
                            Spacer()
                            Text(String(format: "%.2f V", vm.rearOffset))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout.bold())

                        HStack {
                            Slider(
                                value: Binding(
                                    get: { vm.rearOffset },
                                    set: { vm.rearOffset = $0 }
                                ),
                                in: WSModel.offsetMin...WSModel.offsetMax,
                                step: 0.01,
                                onEditingChanged: { editing in
                                    vm.isEditingOffsets = editing
                                    if !editing {
                                        vm.applyMode(shouldSend: true)
                                    }
                                }
                            )
                            .tint(.indigo)

                            Text("±4 V")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))

                    // Front group (indices 2,3)
                    VStack(spacing: 8) {
                        HStack {
                            Label("Front (FR + FL)", systemImage: "plus.forwardslash.minus")
                            Spacer()
                            Text(String(format: "%.2f V", vm.frontOffset))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout.bold())

                        HStack {
                            Slider(
                                value: Binding(
                                    get: { vm.frontOffset },
                                    set: { vm.frontOffset = $0 }
                                ),
                                in: WSModel.offsetMin...WSModel.offsetMax,
                                step: 0.01,
                                onEditingChanged: { editing in
                                    vm.isEditingOffsets = editing
                                    if !editing {
                                        vm.applyMode(shouldSend: true)
                                    }
                                }
                            )
                            .tint(.indigo)

                            Text("±4 V")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
                Text("Inputs · Outputs · Offsets")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// Reusable value card
private struct ValueCard: View {
    let label: String
    let value: Double
    var compact: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.caption).bold().opacity(0.7)
            Text(value.isNaN ? "—" : String(format: "%.3f V", value))
                .font(.system(size: compact ? 10 : 12, design: .monospaced))
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 44 : 50)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15)))
        .shadow(radius: 6, y: 3)
    }
}

// MARK: - Splash

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
