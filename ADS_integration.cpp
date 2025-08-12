// ESP32 AP + WebSocket + ADS1115 (5 V supply)
// Sends all 4 channels together + warning flags if any channel ≥ 4.90 V
// JSON: {"v":[v0,v1,v2,v3],"w":[0,1,0,0],"vdd":5.0,"t":123456}

#include <WiFi.h>
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>
#include <Adafruit_ADS1X15.h>

Adafruit_ADS1115 ads;
AsyncWebServer server(80);
AsyncWebSocket ws("/ws");

const char* SSID = "ESP32-ADS";
const char* PASS = "";         // optional

// UI/stream pacing
const unsigned long intervalMs = 200; // 5 Hz packets
unsigned long lastSend = 0;

// Electrical assumptions
const float VDD = 5.0f;        // ADS1115 supply (single-ended max)
const float WARN_HI = 4.90f;   // warn threshold (near-rail)

void setup() {
  Serial.begin(115200);

  // Wi-Fi AP
  WiFi.mode(WIFI_AP);
  WiFi.softAP(SSID, PASS);
  Serial.print("AP IP: "); Serial.println(WiFi.softAPIP());

  // ADS1115 @ I2C default (SDA=21, SCL=22). Use Wire.begin(SDA,SCL) if custom.
  if (!ads.begin()) {
    Serial.println("ADS1115 not found!");
  }
  ads.setGain(GAIN_TWOTHIRDS);   // widest range (±6.144 V) -> covers 0–5 V inputs
  // Optional: faster data rate if you lower intervalMs
  // ads.setDataRate(RATE_ADS1115_250SPS);

  ws.onEvent([](AsyncWebSocket*, AsyncWebSocketClient* c, AwsEventType t, void*, uint8_t*, size_t){
    if (t == WS_EVT_CONNECT)    Serial.printf("Client %u connected\n", c->id());
    if (t == WS_EVT_DISCONNECT) Serial.printf("Client %u disconnected\n", c->id());
  });
  server.addHandler(&ws);
  server.begin();
}

void loop() {
  ws.cleanupClients();

  unsigned long now = millis();
  if (now - lastSend < intervalMs) return;
  lastSend = now;

  float v[4];
  int   w[4];

  for (int ch = 0; ch < 4; ++ch) {
    int16_t raw = ads.readADC_SingleEnded(ch);
    float volts = ads.computeVolts(raw);

    // Physical sanity clamp for single-ended @ 5 V supply
    if (volts < 0.0f) volts = 0.0f;
    if (volts > VDD)  volts = VDD;

    v[ch] = volts;
    w[ch] = (volts >= WARN_HI) ? 1 : 0; // warn if near the rail
  }

  // Build compact JSON with 6 decimals for volts
  char msg[192];
  snprintf(msg, sizeof(msg),
           "{\"v\":[%.6f,%.6f,%.6f,%.6f],\"w\":[%d,%d,%d,%d],\"vdd\":%.2f,\"t\":%lu}",
           v[0], v[1], v[2], v[3],
           w[0], w[1], w[2], w[3],
           VDD, now);

  ws.textAll(msg);
}
