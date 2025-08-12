import SwiftUI

struct ContentView: View {
    @StateObject private var ws = WebSocketManager()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // App Title
                Text("Dual Voltage Controller")
                    .font(.largeTitle).bold()
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)

                // Wiring Card
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "link")
                        .font(.title2)
                        .foregroundColor(.blue)
                    Text("""
                        **Wiring**  
                        • A GPIO25 → B GPIO34  
                        • A GPIO26 → B GPIO35  
                        • GND ↔ GND (common)  
                        • Inputs → A GPIO34 & GPIO35  
                        (0–3.3 V max)
                        """)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
                .shadow(radius: 2)

                // Live Voltages Card
                Card(title: "Live Voltages", icon: "waveform") {
                    VoltageRow(label: "Raw 1",     value: ws.raw[0],     color: .blue)
                    VoltageRow(label: "Raw 2",     value: ws.raw[1],     color: .blue)
                    VoltageRow(label: "Applied 1", value: ws.applied[0], color: .purple)
                    VoltageRow(label: "Applied 2", value: ws.applied[1], color: .purple)
                    VoltageRow(label: "Received 1",value: ws.received[0],color: .teal)
                    VoltageRow(label: "Received 2",value: ws.received[1],color: .teal)
                }

                // Dynamic Bias Card
                Card(title: "Dynamic Bias", icon: "slider.horizontal.3") {
                    Toggle(isOn: $ws.dynEnabled.onChange(ws.sendDynamicConfig)) {
                        Text("Enable Dynamic Mode")
                            .font(.headline)
                    }
                    .padding(.vertical, 8)

                    ForEach(0..<2) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Bias \(i+1)")
                                Spacer()
                                Text("\(ws.bias[i], specifier: "%.2f") V")
                                    .monospaced()
                            }
                            Slider(
                                value: Binding(
                                    get: { ws.bias[i] },
                                    set: { ws.bias[i] = $0; ws.sendDynamicConfig() }
                                ),
                                in: -3.3...3.3,
                                step: 0.01
                            )
                        }
                        .padding(.vertical, 4)
                    }
                }

                Spacer()
            }
            .padding()
        }
        .onAppear { ws.connect() }
        .onDisappear { ws.disconnect() }
    }

    // MARK: Reusable Cards & Rows
    struct Card<Content: View>: View {
        let title: String, icon: String
        let content: Content
        init(title: String, icon: String, @ViewBuilder content: () -> Content) {
            self.title = title; self.icon = icon; self.content = content()
        }
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(.accentColor)
                    Text(title)
                        .font(.headline)
                }
                content
            }
            .padding()
            .background(Color.black)
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
        }
    }

    struct VoltageRow: View {
        let label: String, value: String
        let color: Color
        var body: some View {
            HStack {
                Text(label)
                Spacer()
                Text("\(value) V")
                    .bold()
                    .foregroundColor(color)
            }
            .font(.subheadline)
            .padding(.vertical, 2)
        }
    }
}

// Utility: call action when binding changes
extension Binding {
    func onChange(_ handler: @escaping ()->Void) -> Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { newVal in wrappedValue = newVal; handler() }
        )
    }
}
