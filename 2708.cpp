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

const float DAC_VREF = 5.0f;   // MCP4728 powered from 5V → can't output > 5.0 V
unsigned long lastSend = 0;
const unsigned long frameMs = 200;

// Offsets set from the app
float offsets[4] = {0,0,0,0};

// helpers
static inline float clampf(float v, float lo, float hi) {
  if (v < lo) v = lo;
  if (v > hi) v = hi;
  return v;
}
static inline uint16_t vToCode(float v) {
  float v_hw = clampf(v, 0.0f, DAC_VREF); // never tell DAC to exceed VREF
  return (uint16_t)lroundf((v_hw / DAC_VREF) * 4095.0f);
}

// send legacy/simple ADS packet:
// {"type":"ads","v":[raw0..raw3],"offs":[off0..off3]}
static void sendAdsPacket(const float vin_raw[4]) {
  char msg[200];
  snprintf(msg, sizeof(msg),
    "{\"type\":\"ads\",\"v\":[%.4f,%.4f,%.4f,%.4f],"
    "\"offs\":[%.3f,%.3f,%.3f,%.3f]}",
    vin_raw[0], vin_raw[1], vin_raw[2], vin_raw[3],
    offsets[0], offsets[1], offsets[2], offsets[3]);
  ws.textAll(msg);
}

// parse messages from app
static void handleWsMessage(void *arg, uint8_t *data, size_t len) {
  AwsFrameInfo *info = (AwsFrameInfo*)arg;
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

  // Use your actual addresses; 0x48/0x60 are common defaults
  ads_ok = ads.begin(); // works with your “last known good” code
  if (!ads_ok) Serial.println("ADS1115 not found!");
  else ads.setGain(GAIN_TWOTHIRDS);

  dac_ok = dac.begin();
  if (!dac_ok) Serial.println("MCP4728 not found!");
  else {
    dac.setChannelValue(MCP4728_CHANNEL_A, vToCode(0), MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
    dac.setChannelValue(MCP4728_CHANNEL_B, vToCode(0), MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
    dac.setChannelValue(MCP4728_CHANNEL_C, vToCode(0), MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
    dac.setChannelValue(MCP4728_CHANNEL_D, vToCode(0), MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
  }
}

void loop() {
  ws.cleanupClients();

  unsigned long now = millis();
  if (now - lastSend < frameMs) return;
  lastSend = now;

  float vin_raw[4] = {0,0,0,0}; // RAW inputs (no offset!)

  if (ads_ok) {
    for (int ch = 0; ch < 4; ++ch) {
      int16_t raw = ads.readADC_SingleEnded(ch);
      float volts = ads.computeVolts(raw); // measured raw input
      // do NOT add offset here; we want to send raw inputs to the app
      vin_raw[ch] = clampf(volts, 0.0f, 5.0f); // ADS on 5V won’t exceed ~5.0
    }
  }

  // Physically set DAC to (raw + offset), but clamp to DAC VREF for hardware
  if (dac_ok) {
    float a = clampf(vin_raw[0] + offsets[0], 0.0f, DAC_VREF);
    float b = clampf(vin_raw[1] + offsets[1], 0.0f, DAC_VREF);
    float c = clampf(vin_raw[2] + offsets[2], 0.0f, DAC_VREF);
    float d = clampf(vin_raw[3] + offsets[3], 0.0f, DAC_VREF);
    dac.setChannelValue(MCP4728_CHANNEL_A, vToCode(a), MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
    dac.setChannelValue(MCP4728_CHANNEL_B, vToCode(b), MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
    dac.setChannelValue(MCP4728_CHANNEL_C, vToCode(c), MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
    dac.setChannelValue(MCP4728_CHANNEL_D, vToCode(d), MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
  }

  // Send the simple ADS packet the app expects
  sendAdsPacket(vin_raw);
}
