#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "esp_timer.h"
#include <math.h>

#include "soc/gpio_struct.h"
#include "soc/gpio_periph.h"
#include "hal/gpio_ll.h"

#include "esp_task_wdt.h"

// --- PIN-MAPPING ---
#define PIN_DATA_0  GPIO_NUM_13
#define PIN_DATA_1  GPIO_NUM_14
#define PIN_DATA_2  GPIO_NUM_27
#define PIN_DATA_3  GPIO_NUM_26
#define PIN_DATA_4  GPIO_NUM_25
#define PIN_DATA_5  GPIO_NUM_33
#define PIN_DATA_6  GPIO_NUM_32
#define PIN_DATA_7  GPIO_NUM_19
#define PIN_DATA_EN GPIO_NUM_18

const gpio_num_t data_pins[8] = {
    PIN_DATA_0, PIN_DATA_1, PIN_DATA_2, PIN_DATA_3,
    PIN_DATA_4, PIN_DATA_5, PIN_DATA_6, PIN_DATA_7
};

static inline void delay_ns(uint32_t ns) {
    uint32_t start = esp_cpu_get_cycle_count();
    uint32_t cycles = (CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ * ns) / 1000;
    while ((esp_cpu_get_cycle_count() - start) < cycles);
}

// --- ATOMARE INTERFACE-FUNKTION ---
// EMV-Version
void IRAM_ATTR send_to_fpga(uint8_t val) {
    // Masken für zeitgleiches Schalten vorbereiten
    uint32_t mask_low_set = 0;   uint32_t mask_low_clr = 0;
    uint32_t mask_high_set = 0;  uint32_t mask_high_clr = 0;

    // Bit-Mapping auf die Hardware-Bänke
    if (val & 0x01) mask_low_set  |= (1 << PIN_DATA_0); else mask_low_clr  |= (1 << PIN_DATA_0);
    if (val & 0x02) mask_low_set  |= (1 << PIN_DATA_1); else mask_low_clr  |= (1 << PIN_DATA_1);
    if (val & 0x04) mask_low_set  |= (1 << PIN_DATA_2); else mask_low_clr  |= (1 << PIN_DATA_2);
    if (val & 0x08) mask_low_set  |= (1 << PIN_DATA_3); else mask_low_clr  |= (1 << PIN_DATA_3);
    if (val & 0x10) mask_low_set  |= (1 << PIN_DATA_4); else mask_low_clr  |= (1 << PIN_DATA_4);
    if (val & 0x20) mask_high_set |= (1 << (PIN_DATA_5 - 32)); else mask_high_clr |= (1 << (PIN_DATA_5 - 32));
    if (val & 0x40) mask_high_set |= (1 << (PIN_DATA_6 - 32)); else mask_high_clr |= (1 << (PIN_DATA_6 - 32));
    if (val & 0x80) mask_low_set  |= (1 << PIN_DATA_7); else mask_low_clr  |= (1 << PIN_DATA_7);

    // --- SCHRITT 1: DATEN ANLEGEN & STROBE AUF 0 (Entspricht Vorlauf der Testbench) ---
    GPIO.out_w1tc = mask_low_clr | (1ULL << PIN_DATA_EN);
    GPIO.out_w1ts = mask_low_set;
    GPIO.out1_w1tc.val = mask_high_clr;
    GPIO.out1_w1ts.val = mask_high_set;

    // Mindestens 200 ns warten.  
    delay_ns(200);

    // --- SCHRITT 2: DATA_EN AKTIVIEREN (Steigende Flanke) ---
    GPIO.out_w1ts = (1ULL << PIN_DATA_EN);
    
    // --- SCHRITT 3: PULS HALTEN (Entspricht den Takten im Glitch-Filter in der TB) ---
    delay_ns(200);

    // --- SCHRITT 4: DATA_EN DEAKTIVIEREN (Fallende Flanke) ---
    GPIO.out_w1tc = (1ULL << PIN_DATA_EN);
    
    // --- SCHRITT 5: NACHLAUF (Gibt dem Glitch-Filter Zeit, auf Null zu fallen) ---
    delay_ns(200);
}


void send_audio_packet(uint8_t samples[10]) {
    send_to_fpga('A');
    send_to_fpga('U');
    send_to_fpga('D');
    for(int i = 0; i < 10; i++) {
        send_to_fpga(samples[i]);
    }
}

// --- AUDIO LOGIK (LUT & SINUS) ---
#define SAMPLE_RATE_HZ 25000
#define PI 3.14159265358979323846

static uint8_t sine_lut[256];

void init_lut() {
    for(int i = 0; i < 256; i++) {
        sine_lut[i] = (uint8_t)(127.5 * (1.0 + sin(2.0 * PI * i / 256.0)));
    }
}

// --- TASK MANAGEMENT ---
void audio_task(void *pvParameters) {
    uint32_t phase_acc[10] = {0};
    uint32_t channel_freqs[10] = {440, 554, 659, 880, 1000, 1200, 1500, 2000, 2500, 3000};
    uint8_t current_samples[10];
    
    // Einmalige Registrierung dieses Tasks beim Watchdog
    esp_task_wdt_add(NULL);

    // Mikrosekunden-basiertes Timing zur Umgehung von FreeRTOS-Tick-Problemen
    // Wir senden alle 2 ms ein Paket (500 Hz Paket-Rate)
    //const int64_t interval_us = 2000; 
    // Für echte 25 kHz Samplerate muss alle 40 Mikrosekunden ein Paket raus!
    const int64_t interval_us = 40;

    int64_t next_wake_us = esp_timer_get_time() + interval_us;

    while(1) {
        // Watchdog für diesen Task zurücksetzen
        esp_task_wdt_reset();

        for(int i = 0; i < 10; i++) {
            phase_acc[i] += (channel_freqs[i] * 256) / SAMPLE_RATE_HZ;
            current_samples[i] = sine_lut[(phase_acc[i] >> 0) % 256];
        }

        // Paket senden
        send_audio_packet(current_samples);

        // Präzises Warten basierend auf dem Hardware-Timer
        int64_t now = esp_timer_get_time();
        if (now < next_wake_us) {
            uint32_t delay_us = (uint32_t)(next_wake_us - now);
            esp_rom_delay_us(delay_us);
        }
        next_wake_us += interval_us;

    }
}

// --- FREQUENZ INTERFACE-FUNKTION (KOMPATIBEL ZUR VERILATOR-TESTBENCH) ---
void send_frequency_packet(const uint32_t freqs[10]) {
    // 1. Synchronisations-Header senden
    send_to_fpga('F');
    send_to_fpga('R');
    send_to_fpga('Q');

    // 2. Alle 10 Kanäle nacheinander als 4 Bytes (Big-Endian / MSB first) senden
    for (int i = 0; i < 10; i++) {
        uint32_t f = freqs[i];
        send_to_fpga((f >> 24) & 0xFF); // Byte 3 (MSB)
        send_to_fpga((f >> 16) & 0xFF); // Byte 2
        send_to_fpga((f >> 8)  & 0xFF); // Byte 1
        send_to_fpga(f         & 0xFF); // Byte 0 (LSB)
    }
}

// --- GAIN INTERFACE-FUNKTION (KOMPATIBEL ZUR VERILATOR-TESTBENCH) ---
void send_gain_update(uint8_t channel, uint16_t gain) {
    // Sicherheitsprüfung analog zur Testbench (nur Kanäle 0-9 sind im FPGA vorhanden)
    if (channel > 9) return;
    
    // 1. Synchronisations-Header senden
    send_to_fpga('G');
    send_to_fpga('A');
    send_to_fpga('N');
    
    // 2. Zielkanal übergeben (0-9)
    send_to_fpga(channel);
    
    // 3. 16-Bit Gain in 2 Bytes zerlegen und als Big-Endian (MSB zuerst) senden
    send_to_fpga((gain >> 8) & 0xFF); // Oberes Byte (MSB)
    send_to_fpga(gain        & 0xFF); // Unteres Byte (LSB)
}


void app_main(void) {
    // 1. GPIO Konfiguration (wie gehabt)
    uint64_t pin_mask = (1ULL << PIN_DATA_EN) | 
                        (1ULL << PIN_DATA_0) | (1ULL << PIN_DATA_1) | 
                        (1ULL << PIN_DATA_2) | (1ULL << PIN_DATA_3) | 
                        (1ULL << PIN_DATA_4) | (1ULL << PIN_DATA_5) | 
                        (1ULL << PIN_DATA_6) | (1ULL << PIN_DATA_7);

    gpio_config_t io_conf = {
        .pin_bit_mask = pin_mask,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_ENABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io_conf);

    // Initialer Zustand: Alles auf Null
    GPIO.out_w1tc = pin_mask;
    GPIO.out1_w1tc.val = (1ULL << (32-32)) | (1ULL << (33-32));

    // Konfiguration für 6.1:
    // Wir setzen idle_core_mask auf 0, um den Watchdog 
    // für die IDLE-Tasks auf ALLEN Cores zu deaktivieren.
    esp_task_wdt_config_t wdt_config = {
        .timeout_ms = 10000,    // 10 Sekunden Puffer
        .idle_core_mask = 0,    // WICHTIG: Keine Überwachung der Idle-Tasks
        .trigger_panic = true,
    };
    
    ESP_ERROR_CHECK(esp_task_wdt_reconfigure(&wdt_config));

    init_lut();
    printf("ESP32-Interface initialisiert. Starte FPGA-Konfiguration...\n");

    // --- INITIALISIERUNG ANALOG ZUR TESTBENCH ---
    // Die 10 exakten Frequenzwörter aus Testbench (LW & MW)
    uint32_t my_freqs[10] = {
        0x03E978D5, 0x046452D1, 0x05C8500D, 0x2467C924, 0x24DD2F1B,
        0x0FE5890C, 0x19934566, 0x1999999A, 0x1FC7A163, 0x2889A027
    };
    
    /* Neue Frequenzen: LW (153, 171, 225) und diverse MW Sender
    uint32_t my_freqs[10] = {
        0x03E978D5, // CH0: 153 kHz
        0x046452D1, // CH1: 171 kHz
        0x05C8500D, // CH2: 225 kHz
        0x2467C924, // CH3: 1422 kHz
        0x24DD2F1B, // CH4: 1440 kHz
        0x0FE5890C, // CH5: 621 kHz
        0x19934566, // CH6: 999 kHz
        0x1999999A, // CH7: 1000 kHz
        0x1FC7A163, // CH8: 1242 kHz
        0x2889A027  // CH9: 1584 kHz
    };
    */

    // Einmalig Frequenzen an das FPGA übertragen
    send_frequency_packet(my_freqs);

    // Einmalig Gains)initialisieren, wie in der Testbench
    send_gain_update(0, 256);   // CH0: -48 dB
    send_gain_update(1, 4096);  // CH1: -24 dB
    send_gain_update(2, 16384); // CH2: -12 dB

    printf("Konfiguration abgeschlossen. Starte 25-kHz Audio-Streaming-Task...\n");

    // Audio-Streaming-Task auf Core 1 starten (Läuft autark im 4µs-Takt)
    xTaskCreatePinnedToCore(audio_task, "audio_task", 4096, NULL, 10, NULL, 1);
}
