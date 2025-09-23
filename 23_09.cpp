// ESP32 + EVAL-AD5593R-PMDZ (0–5 V I/O) using LukasJanavicius AD5593R lib
#include <WiFi.h>
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>
#include <Wire.h>
#include <ArduinoJson.h>
#include <AD5593R.h>

// ---------- Wi-Fi ----------
const char* SSID = "ADSUSPENSION1";
const char* PASS = "";
AsyncWebServer server(80);
AsyncWebSocket ws("/ws");

// ---------- AD5593R ----------
AD5593R adac(-1);                 // pass -1 if you are NOT toggling A0 via a GPIO
static const float VSPAN = 5.0f;  // 2.5 V internal ref ×2

// App state
float offsets[4] = {0,0,0,0};
unsigned long lastSend = 0;
const unsigned long frameMs = 200;

// helpers
static inline float clampf(float v, float lo, float hi) {
  if (v < lo) v = lo;
  if (v > hi) v = hi;
  return v;
}

// JSON packet: {"type":"ads","v":[raw0..3],"offs":[off0..3],"mcp":[out0..3]}
static void sendAdsPacket(const float vin_raw[4], const float vout[4]) {
  char msg[280];
  snprintf(msg, sizeof(msg),
    "{\"type\":\"ads\",\"v\":[%.4f,%.4f,%.4f,%.4f],"
    "\"offs\":[%.3f,%.3f,%.3f,%.3f],"
    "\"mcp\":[%.4f,%.4f,%.4f,%.4f]}",
    vin_raw[0], vin_raw[1], vin_raw[2], vin_raw[3],
    offsets[0], offsets[1], offsets[2], offsets[3],
    vout[0], vout[1], vout[2], vout[3]);
  ws.textAll(msg);
}

static void handleWsMessage(void *arg, uint8_t *data, size_t len) {
  auto *info = (AwsFrameInfo*)arg;
  if (!(info->final && info->index == 0 && info->len == len && info->opcode == WS_TEXT)) return;

  StaticJsonDocument<256> doc;
  if (deserializeJson(doc, (const char*)data, len)) return;

  const char* cmd = doc["cmd"] | "";
  if (strcmp(cmd, "setOffset") == 0) {
    JsonArray arr = doc["v"].as<JsonArray>();
    if (arr.size() == 4) {
      for (int i=0;i<4;i++) offsets[i] = arr[i] | 0.0;
      Serial.printf("Offsets updated: %.3f, %.3f, %.3f, %.3f\n",
        offsets[0], offsets[1], offsets[2], offsets[3]);
    }
  }
}

void setup() {
  Serial.begin(115200);

  // IMPORTANT: if AD5593R VDD = 5 V, use an I²C level shifter (3.3V<->5V)
  Wire.begin(21, 22);
  Wire.setClock(400000);

  WiFi.mode(WIFI_AP);
  WiFi.softAP(SSID, PASS);
  Serial.print("AP IP: "); Serial.println(WiFi.softAPIP());

  ws.onEvent([](AsyncWebSocket* s, AsyncWebSocketClient* c, AwsEventType t, void* arg, uint8_t* data, size_t len){
    if (t == WS_EVT_CONNECT)    Serial.printf("Client %u connected\n", c->id());
    if (t == WS_EVT_DISCONNECT) Serial.printf("Client %u disconnected\n", c->id());
    if (t == WS_EVT_DATA)       handleWsMessage(arg, data, len);
  });
  server.addHandler(&ws);
  server.begin();

  // ---- AD5593R init ----
  adac.enable_internal_Vref();    // use 2.5 V internal ref
  adac.set_ADC_max_2x_Vref();     // ADC span 0–5 V
  adac.set_DAC_max_2x_Vref();     // DAC span 0–5 V

  // Configure channels: IO0..3 as ADC, IO4..7 as DAC
  for (uint8_t ch = 0; ch < 4; ++ch) adac.configure_ADC(ch);
  for (uint8_t ch = 4; ch < 8; ++ch) adac.configure_DAC(ch);

  // Mirror inputs to outputs at startup
  for (uint8_t i = 0; i < 4; ++i) {
    float v_in = adac.read_ADC(i);
    float v_mirror = clampf(v_in, 0.0f, VSPAN);
    adac.write_DAC(4 + i, v_mirror);
  }

  Serial.println("AD5593R ready: ADC IO0..3, DAC IO4..7, span 0–5 V (mirroring at startup)");
}

void loop() {
  ws.cleanupClients();

  unsigned long now = millis();
  if (now - lastSend < frameMs) return;
  lastSend = now;

  // Read RAW inputs (0..5 V), no offset
  float vin_raw[4] = {0,0,0,0};
  for (int ch = 0; ch < 4; ++ch) {
    float v = adac.read_ADC((uint8_t)ch);
    vin_raw[ch] = clampf(v, 0.0f, VSPAN);
  }

  // Compute outputs = raw + offset (clamped), write DAC IO4..7
  float vout[4] = {0,0,0,0};
  for (int i = 0; i < 4; ++i) {
    vout[i] = clampf(vin_raw[i] + offsets[i], 0.0f, VSPAN);
    adac.write_DAC((uint8_t)(4 + i), vout[i]);
  }

  // Send packet the app expects
  sendAdsPacket(vin_raw, vout);
}
