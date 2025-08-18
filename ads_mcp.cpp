#include <WiFi.h>
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>
#include <Wire.h>
#include <Adafruit_ADS1X15.h>
#include <Adafruit_MCP4728.h>
#include <ArduinoJson.h>

// Wi-Fi AP
const char* SSID = "ESP32-ADS";
const char* PASS = "";

AsyncWebServer server(80);
AsyncWebSocket ws("/ws");

// I2C devices
Adafruit_ADS1115 ads;
Adafruit_MCP4728 dac;

bool ads_ok = false, dac_ok = false;

// Timing
unsigned long lastAdsSend = 0;
const unsigned long adsIntervalMs = 200;

// Constants
const float ADS_VDD = 5.0f;
const float DAC_VREF = 5.0f;

static inline uint16_t vToCode(float v) {
  if (v < 0) v = 0;
  if (v > DAC_VREF) v = DAC_VREF;
  return (uint16_t)lroundf((v / DAC_VREF) * 4095.0f);
}

// --- Messaging helpers ---
void sendStatus(bool ads_ok, bool dac_ok) {
  char msg[128];
  snprintf(msg, sizeof(msg),
           "{\"type\":\"status\",\"ads\":\"%s\",\"dac\":\"%s\"}",
           ads_ok ? "ok" : "not found",
           dac_ok ? "ok" : "not found");
  ws.textAll(msg);
}

void sendAdsPacket(float v0, float v1, float v2, float v3) {
  char msg[160];
  snprintf(msg, sizeof(msg),
           "{\"type\":\"ads\",\"v\":[%.6f,%.6f,%.6f,%.6f]}",
           v0, v1, v2, v3);
  ws.textAll(msg);
}

void setDacAll(float a, float b, float c, float d) {
  dac.setChannelValue(MCP4728_CHANNEL_A, vToCode(a),
                      MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
  dac.setChannelValue(MCP4728_CHANNEL_B, vToCode(b),
                      MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
  dac.setChannelValue(MCP4728_CHANNEL_C, vToCode(c),
                      MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
  dac.setChannelValue(MCP4728_CHANNEL_D, vToCode(d),
                      MCP4728_VREF_VDD, MCP4728_GAIN_1X, MCP4728_PD_MODE_NORMAL);
}

// --- Setup ---
void setup() {
  Serial.begin(115200);
  Wire.begin(21, 22);
  Wire.setClock(400000);

  // Wi-Fi AP
  WiFi.mode(WIFI_AP);
  WiFi.softAP(SSID, PASS);
  Serial.print("AP IP: ");
  Serial.println(WiFi.softAPIP());

  ws.onEvent([](AsyncWebSocket* s, AsyncWebSocketClient* c,
                AwsEventType t, void* arg, uint8_t* data, size_t len) {
    if (t == WS_EVT_CONNECT) {
      Serial.printf("Client %u connected\n", c->id());
      sendStatus(ads_ok, dac_ok); // send status to *this* client
    }
    if (t == WS_EVT_DISCONNECT)
      Serial.printf("Client %u disconnected\n", c->id());
  });

  server.addHandler(&ws);
  server.begin();

  // Init devices
  ads_ok = ads.begin(0x48);
  if (!ads_ok) Serial.println("ADS1115 not found!");
  else ads.setGain(GAIN_TWOTHIRDS);

  dac_ok = dac.begin(0x60);
  if (!dac_ok) Serial.println("MCP4728 not found!");
  else setDacAll(0, 0, 0, 0);

  // Initial status broadcast
  sendStatus(ads_ok, dac_ok);
}

// --- Loop ---
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
        if (volts < 0) volts = 0;
        if (volts > ADS_VDD) volts = ADS_VDD;
        v[ch] = volts;
      }
      sendAdsPacket(v[0], v[1], v[2], v[3]);

      if (dac_ok) setDacAll(v[0], v[1], v[2], v[3]);
    }
  }
}
