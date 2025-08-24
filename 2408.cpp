#include <WiFi.h>
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>
#include <Wire.h>
#include <Adafruit_ADS1X15.h>
#include <Adafruit_MCP4728.h>
#include <ArduinoJson.h>

// ---------- Wi-Fi ----------
const char* SSID = "ADSUSPENSION";
const char* PASS = "";
AsyncWebServer server(80);
AsyncWebSocket ws("/ws");

// ---------- I2C Devices ----------
Adafruit_ADS1115 ads;
Adafruit_MCP4728 dac;

const float ADS_VDD = 5.0f;    // ADS powered from 5V
const float DAC_VREF = 5.0f;   // DAC Vref = VDD (5V)
unsigned long lastAdsSend = 0;
const unsigned long adsIntervalMs = 200;

// ---------- Offsets (set from app) ----------
float offsets[4] = {0,0,0,0};  // per-channel bias

// helper: clamp to 0..5 V
static inline float clamp5V(float v) {
  if (v < 0) v = 0;
  if (v > 5.0) v = 5.0;
  return v;
}

// helper: volts -> DAC code
static inline uint16_t vToCode(float v) {
  return (uint16_t)lroundf((clamp5V(v) / DAC_VREF) * 4095.0f);
}

// send ADS + offsets to app
void sendAdsPacket(float v0, float v1, float v2, float v3) {
  char msg[200];
  snprintf(msg, sizeof(msg),
    "{\"type\":\"ads\",\"v\":[%.4f,%.4f,%.4f,%.4f],"
    "\"offs\":[%.3f,%.3f,%.3f,%.3f]}",
    v0, v1, v2, v3,
    offsets[0], offsets[1], offsets[2], offsets[3]);
  ws.textAll(msg);
}

// write voltages to DAC
void setDacAll(float a, float b, float c, float d) {
  dac.setChannelValue(MCP4728_CHANNEL_A, vToCode(a), MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
  dac.setChannelValue(MCP4728_CHANNEL_B, vToCode(b), MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
  dac.setChannelValue(MCP4728_CHANNEL_C, vToCode(c), MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
  dac.setChannelValue(MCP4728_CHANNEL_D, vToCode(d), MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
}

// parse WebSocket messages
void handleWsMessage(void *arg, uint8_t *data, size_t len) {
  AwsFrameInfo *info = (AwsFrameInfo*)arg;
  if (!(info->final && info->index == 0 && info->len == len && info->opcode == WS_TEXT)) return;

  StaticJsonDocument<256> doc;
  if (deserializeJson(doc, (const char*)data, len)) return;

  const char* cmd = doc["cmd"] | "";
  if (strcmp(cmd, "setOffset") == 0) {
    JsonArray arr = doc["v"].as<JsonArray>();
    if (arr.size() == 4) {
      for (int i=0;i<4;i++) offsets[i] = arr[i] | 0.0;
      Serial.printf("Offsets updated: %.3f, %.3f, %.3f, %.3f\n", offsets[0], offsets[1], offsets[2], offsets[3]);
    }
  }
}

bool ads_ok=false, dac_ok=false;

void setup() {
  Serial.begin(115200);
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

  ads_ok = ads.begin();
  if (!ads_ok) Serial.println("ADS1115 not found!");
  else ads.setGain(GAIN_TWOTHIRDS);

  dac_ok = dac.begin();
  if (!dac_ok) Serial.println("MCP4728 not found!");
  else setDacAll(0,0,0,0);
}

void loop() {
  ws.cleanupClients();

  unsigned long now = millis();
  static float v[4];
  if (now - lastAdsSend >= adsIntervalMs) {
    lastAdsSend = now;

    if (ads_ok) {
      for (int ch = 0; ch < 4; ++ch) {
        int16_t raw = ads.readADC_SingleEnded(ch);
        float volts = ads.computeVolts(raw);
        v[ch] = clamp5V(volts + offsets[ch]);  // apply offset and clamp
      }
    }

    if (dac_ok) setDacAll(v[0], v[1], v[2], v[3]);
    sendAdsPacket(v[0], v[1], v[2], v[3]);
  }
}
