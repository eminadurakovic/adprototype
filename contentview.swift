import SwiftUI

struct ContentView: View {
    @StateObject private var ws = WebSocketManager()

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("ESP32 Voltage Dashboard").font(.title3).bold()
                Spacer()
                Circle().fill(ws.isConnected ? .green : .red).frame(width: 10, height: 10)
            }

            GroupBox("Live Voltages") {
                line("Raw (A)", ws.raw)
                line("Applied (A)", ws.applied)
                line("Received (B)", ws.received)
            }

            GroupBox("Offset Control") {
                VStack(spacing: 12) {
                    Slider(value: $ws.offset, in: -1.0...1.0, step: 0.01)
                    Text("Offset: \(ws.offset, specifier: "%.2f") V")
                    HStack {
                        Button("Send Offset") { ws.sendOffset() }
                            .frame(maxWidth: .infinity).padding().background(Color.blue).foregroundColor(.white).cornerRadius(8)
                        Button("Apply") { ws.apply() }
                            .frame(maxWidth: .infinity).padding().background(Color.green).foregroundColor(.white).cornerRadius(8)
                    }
                }
            }

            Spacer()
        }
        .padding()
        .onAppear { ws.connect() }
        .onDisappear { ws.disconnect() }
    }

    @ViewBuilder
    private func line(_ title: String, _ val: String) -> some View {
        HStack { Text(title); Spacer(); Text("\(val) V").bold().foregroundColor(.blue) }
            .padding(.vertical, 2)
    }
}
