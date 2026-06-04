#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_system.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "driver/gpio.h"
#include "esp_timer.h"
#include "esp_task_wdt.h"
#include "esp_rom_sys.h"

// Hardware-Register-Zugriffe für ultraschnelle GPIO-Schaltzeiten
#include "soc/gpio_struct.h"
#include "soc/gpio_periph.h"
#include "hal/gpio_ll.h"

// Native lwIP RAW-Header
#include "lwip/udp.h"
#include "lwip/pbuf.h"
#include "lwip/ip_addr.h"

// --- NETZWERK KONFIGURATION ---
#define WIFI_SSID       "DEIN_NETZWERK_NAME"
#define WIFI_PASS       "DEIN_NETZWERK_PASSW"

#define START_PORT      1234
#define NUM_LISTENERS   40  

// --- FPGA TAKT FÜR NCO BERECHNUNG ---
#define FPGA_CLOCK_HZ   10000000.0 

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

#define SAMPLE_RATE_HZ 25000

static const char *TAG = "UDP_AUDIO_RAW";

// --- RINGPUFFER DEFINITION ---
#define BUFFER_SIZE 2*1024 // Muss eine Potenz von 2 sein (256, 512, 1024) für schnelles Bitmask-Wrapping


// Spinlock für Hard-Realtime FPGA-Transfers
static portMUX_TYPE fpga_mux = portMUX_INITIALIZER_UNLOCKED;

typedef struct {
    uint8_t storage[BUFFER_SIZE];
    volatile uint32_t head; // Schreib-Index (wird nur von Core 0/Netzwerk verändert)
    volatile uint32_t tail; // Lese-Index (wird nur von Core 1/Audio verändert)
    uint8_t last_sample;    // Für den Fall eines Underruns (Zero-Order Hold Backup)
    uint32_t underrun_counter; // Zählt, wie lange der Puffer schon LEER ist
    bool is_streaming;         // Sagt uns, ob der Kanal aktiv läuft oder im Sync-Modus ist
} channel_buffer_t;

static channel_buffer_t channel_buffers[NUM_LISTENERS];

// --- STATE-ARRAY FÜR DIE NCOs ---
typedef struct {
    int port;
    uint32_t freq_hz;
    uint16_t gain;
} nco_state_t;

static nco_state_t nco_states[NUM_LISTENERS];
static uint32_t current_freq_words[NUM_LISTENERS]; // Cacht die 32-Bit Frequenzwörter


// Nano-Sekunden-Verzögerung für die FPGA-Bus-Timings
static inline void delay_ns(uint32_t ns) {
    uint32_t start = esp_cpu_get_cycle_count();
    uint32_t cycles = (CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ * ns) / 1000;
    while ((esp_cpu_get_cycle_count() - start) < cycles);
}


// Einmalig in app_main() aufrufen!
// =========================================================================
// HARDWARE-OPTIMIERUNG: GPIO LOOK-UP TABLES (LUT)
// =========================================================================
// HINTERGRUND: 
// Da die 8 Datenbits auf unserem Board physisch verstreut liegen (13, 14, etc.)
// und zudem zwei völlig separate GPIO-Register kreuzen (Pins 0-31 vs. Pins 32-39),
// wäre eine Live-Berechnung über Bit-Shifts und if-Abfragen im 25-kHz-Audio-Task
// strssig. Sie hat beim 40-Kanal-Ausbau das "Slowmo-Audio"-Problem verursacht.
//
// LÖSUNG:
// Wir berechnen beim Booten einmalig alle 256 möglichen Register-Zustände im 
// Voraus. Im zeitkritischen Stream-Loop greift die CPU per O(1) direkt auf die
// fertigen Masken im RAM zu. Das eliminiert sämtliche CPU-Verzweigungen (Branches)
// und senkt die Übertragungszeit von ~600ns auf ~300ns pro Byte.
// =========================================================================
static uint32_t lut_low_set[256];   // Set-Maske für GPIOs 0-31  (Datenbits 0,1,2,3,4,7)
static uint32_t lut_low_clr[256];   // Clear-Maske für GPIOs 0-31
static uint32_t lut_high_set[256];  // Set-Maske für GPIOs 32-39 (Datenbits 5,6)
static uint32_t lut_high_clr[256];  // Clear-Maske für GPIOs 32-39

/**
 * @brief Initialisiert die GPIO Look-Up-Table beim Systemstart.
 * Übersetzt die logische Bit-Architektur (0..7) in die physischen ESP32-Register.
 */
void init_gpio_lut() {
    for (int i = 0; i < 256; i++) {
        // Tabellenzeile initialisieren
        lut_low_set[i] = 0; lut_low_clr[i] = 0;
        lut_high_set[i] = 0; lut_high_clr[i] = 0;

        // Bit 0 -> PIN_DATA_0 (GPIO 13)
        if (i & 0x01) lut_low_set[i]  |= (1 << PIN_DATA_0); else lut_low_clr[i]  |= (1 << PIN_DATA_0);
        // Bit 1 -> PIN_DATA_1 (GPIO 14)
        if (i & 0x02) lut_low_set[i]  |= (1 << PIN_DATA_1); else lut_low_clr[i]  |= (1 << PIN_DATA_1);
        // Bit 2 -> PIN_DATA_2 (GPIO 27)
        if (i & 0x04) lut_low_set[i]  |= (1 << PIN_DATA_2); else lut_low_clr[i]  |= (1 << PIN_DATA_2);
        // Bit 3 -> PIN_DATA_3 (GPIO 26)
        if (i & 0x08) lut_low_set[i]  |= (1 << PIN_DATA_3); else lut_low_clr[i]  |= (1 << PIN_DATA_3);
        // Bit 4 -> PIN_DATA_4 (GPIO 25)
        if (i & 0x10) lut_low_set[i]  |= (1 << PIN_DATA_4); else lut_low_clr[i]  |= (1 << PIN_DATA_4);
        
        // ACHTUNG: Die Pins 32 und 33 liegen im sekundären GPIO-Register (out1).
        // Daher muss hier zwingend der Bit-Offset (-32) abgezogen werden!
        // Bit 5 -> PIN_DATA_5 (GPIO 33)
        if (i & 0x20) lut_high_set[i] |= (1 << (PIN_DATA_5 - 32)); else lut_high_clr[i] |= (1 << (PIN_DATA_5 - 32));
        // Bit 6 -> PIN_DATA_6 (GPIO 32)
        if (i & 0x40) lut_high_set[i] |= (1 << (PIN_DATA_6 - 32)); else lut_high_clr[i] |= (1 << (PIN_DATA_6 - 32));
        
        // Bit 7 -> PIN_DATA_7 (GPIO 19)
        if (i & 0x80) lut_low_set[i]  |= (1 << PIN_DATA_7); else lut_low_clr[i]  |= (1 << PIN_DATA_7);
    }
}

// Atomares FPGA Interface - EXTREM OPTIMIERT
/**
 * @brief Schiebt ein Byte atomar und ohne Rechenoverhead auf den FPGA-Bus.
 * Läuft im Hard-Realtime-Kontext (Core 1, abgeschaltete Interrupts).
 * * @param val Das zu übertragende Byte (Kommando-Header oder Audio-Sample)
 */
void IRAM_ATTR send_to_fpga(uint8_t val) {
    // 1. SCHRITT: Datenbits anlegen
    // Wir cleren alte Datenbits UND den Enable-Pin gleichzeitig, um Glitches zu vermeiden.
    GPIO.out_w1tc = lut_low_clr[val] | (1ULL << PIN_DATA_EN);
    GPIO.out_w1ts = lut_low_set[val];
    
    // Sekundäres Hardware-Register für Pins 32/33 beschreiben
    GPIO.out1_w1tc.val = lut_high_clr[val];
    GPIO.out1_w1ts.val = lut_high_set[val];
    
    // Setup-Zeit für das FPGA-Eingangsregister.
    // Der digitale 100-MHz-Glitchfilter benötigt hardwareseitig stabilen Pegel.
    delay_ns(100); 

    // 2. SCHRITT: Strobe auslösen (DATA_EN -> HIGH)
    // Das mcu_rx-Modul im FPGA tastet die Daten bei dieser steigenden Flanke ab.
    GPIO.out_w1ts = (1ULL << PIN_DATA_EN);
    delay_ns(100); 

    // 3. SCHRITT: Bus-Zyklus beenden (DATA_EN -> LOW)
    GPIO.out_w1tc = (1ULL << PIN_DATA_EN);
    delay_ns(100); 
}


/*  
// Atomares FPGA Interface
void IRAM_ATTR send_to_fpga(uint8_t val) {
    uint32_t mask_low_set = 0;   uint32_t mask_low_clr = 0;
    uint32_t mask_high_set = 0;  uint32_t mask_high_clr = 0;

    if (val & 0x01) mask_low_set  |= (1 << PIN_DATA_0); else mask_low_clr  |= (1 << PIN_DATA_0);
    if (val & 0x02) mask_low_set  |= (1 << PIN_DATA_1); else mask_low_clr  |= (1 << PIN_DATA_1);
    if (val & 0x04) mask_low_set  |= (1 << PIN_DATA_2); else mask_low_clr  |= (1 << PIN_DATA_2);
    if (val & 0x08) mask_low_set  |= (1 << PIN_DATA_3); else mask_low_clr  |= (1 << PIN_DATA_3);
    if (val & 0x10) mask_low_set  |= (1 << PIN_DATA_4); else mask_low_clr  |= (1 << PIN_DATA_4);
    if (val & 0x20) mask_high_set |= (1 << (PIN_DATA_5 - 32)); else mask_high_clr |= (1 << (PIN_DATA_5 - 32));
    if (val & 0x40) mask_high_set |= (1 << (PIN_DATA_6 - 32)); else mask_high_clr |= (1 << (PIN_DATA_6 - 32));
    if (val & 0x80) mask_low_set  |= (1 << PIN_DATA_7); else mask_low_clr  |= (1 << PIN_DATA_7);

    GPIO.out_w1tc = mask_low_clr | (1ULL << PIN_DATA_EN);
    GPIO.out_w1ts = mask_low_set;
    GPIO.out1_w1tc.val = mask_high_clr;
    GPIO.out1_w1ts.val = mask_high_set;
    delay_ns(100);

    GPIO.out_w1ts = (1ULL << PIN_DATA_EN);
    delay_ns(100);

    GPIO.out_w1tc = (1ULL << PIN_DATA_EN);
    delay_ns(100);
}
*/

void send_audio_packet(const uint8_t samples[40]) {
    send_to_fpga('A');
    send_to_fpga('U');
    send_to_fpga('D');
    for(int i = 0; i < 40; i++) {
        send_to_fpga(samples[i]);
    }
}

void send_frequency_packet(const uint32_t freqs[40]) {
    send_to_fpga('F');
    send_to_fpga('R');
    send_to_fpga('Q');
    for (int i = 0; i < 40; i++) {
        uint32_t f = freqs[i];
        send_to_fpga((f >> 24) & 0xFF);
        send_to_fpga((f >> 16) & 0xFF);
        send_to_fpga((f >> 8)  & 0xFF);
        send_to_fpga(f         & 0xFF);
    }
}

void send_gain_update(uint8_t channel, uint16_t gain) {
    if (channel > 39) return;
    send_to_fpga('G');
    send_to_fpga('A');
    send_to_fpga('N');
    send_to_fpga(channel);
    send_to_fpga((gain >> 8) & 0xFF);
    send_to_fpga(gain        & 0xFF);
}

// --- ERWEITERTER lwIP NATIVE RAW UDP CALLBACK ---
static void native_udp_recv_callback(void *arg, struct udp_pcb *pcb, struct pbuf *p, const ip_addr_t *addr, u16_t port) {
    if (p != NULL) {
        int channel = pcb->local_port - START_PORT;

        if (channel >= 0 && channel < NUM_LISTENERS) {
            channel_buffer_t *buf = &channel_buffers[channel];

            // lwIP-Pakete können fragmentiert sein (pbuf-Kette). Wir iterieren sauber durch.
            struct pbuf *q;
            
            for (q = p; q != NULL; q = q->next) {
                uint8_t *payload_bytes = (uint8_t *)q->payload;
                
                for (int i = 0; i < q->len; i++) {
                    uint32_t next_head = (buf->head + 1) & (BUFFER_SIZE - 1);
                    
                    // Prüfen auf Buffer-Overflow (wenn Head auf Tail aufläuft)
                    if (next_head != buf->tail) {
                        buf->storage[buf->head] = payload_bytes[i];
                        
                        // HIER: Erzwinge, dass das Byte im SRAM steht,
                        portMEMORY_BARRIER();                         
                        buf->head = next_head;

                    } else {
                        // Buffer voll! Hier könnte man optional Statistik-Zähler erhöhen
                        break; 
                    }
                }
            }
        }
        pbuf_free(p);
    }
}


// --- CALLBACK PORT 5000 (FREQUENZEN & PORTS) ---
static void control_freq_recv_callback(void *arg, struct udp_pcb *pcb, struct pbuf *p, const ip_addr_t *addr, u16_t port) {
    if (p == NULL) return;

    // Kopiere Payload sicher in lokalen String-Buffer (max 512 Bytes)
    char buf[512];
    int len = (p->tot_len < sizeof(buf) - 1) ? p->tot_len : (sizeof(buf) - 1);
    pbuf_copy_partial(p, buf, len, 0);
    buf[len] = '\0';

    char *saveptr;
    char *token = strtok_r(buf, " ", &saveptr);
    int nco_idx = 0;
    bool changed = false;

    // Format zerlegen: "1234:603000 1235:828000 ..."
    while (token != NULL && nco_idx < NUM_LISTENERS) {
        int audio_port;
        uint32_t freq;
        if (sscanf(token, "%d:%lu", &audio_port, &freq) == 2) {
            nco_states[nco_idx].port = audio_port;
            nco_states[nco_idx].freq_hz = freq;
            
            // Frequenz in NCO Tuning Word umrechnen: Word = (Frequenz / FPGA_Takt) * 2^32
            double f_word = ((double)freq / FPGA_CLOCK_HZ) * 4294967296.0;
            current_freq_words[nco_idx] = (uint32_t)f_word;
            
            changed = true;
            nco_idx++;
        }
        token = strtok_r(NULL, " ", &saveptr);
    }

    // Wenn Daten gültig sind -> Atomar zum FPGA senden
    if (changed) {
        taskENTER_CRITICAL(&fpga_mux);
        send_frequency_packet(current_freq_words);
        taskEXIT_CRITICAL(&fpga_mux);
    }

    pbuf_free(p);
}


// --- CALLBACK PORT 8888 (GAIN) ---
static void control_gain_recv_callback(void *arg, struct udp_pcb *pcb, struct pbuf *p, const ip_addr_t *addr, u16_t port) {
    if (p == NULL) return;

    char buf[64];
    int len = (p->tot_len < sizeof(buf) - 1) ? p->tot_len : (sizeof(buf) - 1);
    pbuf_copy_partial(p, buf, len, 0);
    buf[len] = '\0';

    uint32_t freq_hz;
    float gain_float;
    
    // Format zerlegen: "603000:0.854321"
    if (sscanf(buf, "%lu:%f", &freq_hz, &gain_float) == 2) {
        // Welcher NCO hat diese Frequenz?
        for (int i = 0; i < NUM_LISTENERS; i++) {
            if (nco_states[i].freq_hz == freq_hz) {
                
                // Gain normieren (0.0 - 1.0) auf (0 - 65535)
                if (gain_float < 0.0f) gain_float = 0.0f;
                if (gain_float > 1.0f) gain_float = 1.0f;
                uint16_t gain_int = (uint16_t)(gain_float * 65535.0f);
                
                nco_states[i].gain = gain_int;

                // Atomar zum FPGA senden
                taskENTER_CRITICAL(&fpga_mux);
                send_gain_update(i, gain_int);
                taskEXIT_CRITICAL(&fpga_mux);
                break; // NCO gefunden, Abbruch der Suche
            }
        }
    }
    pbuf_free(p);
}


// --- AUDIO STREAMING TASK (CORE 1) ---
void audio_task(void *pvParameters) {
    uint8_t tx_buffer[40];
    esp_task_wdt_add(NULL);

    const int64_t interval_us = 40; // 25 kHz
    int64_t next_wake_us = esp_timer_get_time() + interval_us;

    while(1) {
        esp_task_wdt_reset();

        for(int i = 0; i < 40; i++) {
            channel_buffer_t *buf = &channel_buffers[i];
            
            // 1. Aktuellen Füllstand berechnen
            uint32_t fill_level = (buf->head >= buf->tail) ? 
                                  (buf->head - buf->tail) : 
                                  (BUFFER_SIZE - (buf->tail - buf->head));

            // 2. Zustand: Warten auf anfängliche Puffer-Füllung (Vorspannen)
            if (!buf->is_streaming) {
                // FFmpeg schickt Blöcke. Wenn min. 120 Samples da sind, legen wir los.
                if (fill_level >= 120) { 
                    buf->is_streaming = true;
                    buf->underrun_counter = 0;
                } else {
                    // Noch nicht genug Daten -> Absolute Stille im AUD-Frame ausgeben
                    tx_buffer[i] = 128; 
                    continue; 
                }
            }

            // 3. Zustand: Aktives Abspielen
            if (buf->tail != buf->head) {
                // Daten da! Normal auslesen und in den AUD-Frame packen
                buf->last_sample = buf->storage[buf->tail];
                buf->tail = (buf->tail + 1) & (BUFFER_SIZE - 1);
                buf->underrun_counter = 0; // Fehlerzähler zurücksetzen
            } else {
                // HIER greift jetzt das Zero-Order Hold!
                buf->underrun_counter++;
                
                if (buf->underrun_counter > 50) { 
                    // Das Netzwerk ist seit > 2ms tot (50 Samples * 40µs). 
                    // Stream ist wohl abgerissen -> Zurück in den Sync-Modus wechseln!
                    buf->is_streaming = false;
                    buf->last_sample = 128; // Sanft auf Mitte setzen
                } else {
                    // MICRO-JITTER! Der AUD-Frame behält einfach "buf->last_sample".
                    // Es wird KEIN 'continue' aufgerufen, der alte Wert wird gehalten!
                }
            }
            
            tx_buffer[i] = buf->last_sample;
        }

        // --- HARD REALTIME TRANSFER ZUM FPGA ---
        // Interrupts auf diesem Core HART abschalten!
        taskENTER_CRITICAL(&fpga_mux);

        // Der AUD-Frame enthält jetzt entweder echte Daten, 
        // das gehaltene ZOH-Sample bei Jitter, oder saubere 128 bei Stille.
        send_audio_packet(tx_buffer);

        // Interrupts wieder zulassen
        taskEXIT_CRITICAL(&fpga_mux);  
        // ---------------------------------------

        int64_t now = esp_timer_get_time();
        if (now < next_wake_us) {
            uint32_t delay_us = (uint32_t)(next_wake_us - now);
            esp_rom_delay_us(delay_us);
        }
        next_wake_us += interval_us;
    }
}

// Wi-Fi Event Handler
static void wifi_event_handler(void* arg, esp_event_base_t event_base, int32_t event_id, void* event_data) {
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        esp_wifi_connect();
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t* event = (ip_event_got_ip_t*) event_data;
        ESP_LOGI(TAG, "Verbunden! Lokale ESP32-IP: " IPSTR, IP2STR(&event->ip_info.ip));
    }
}

void wifi_init_sta(void) {
    ESP_ERROR_CHECK(esp_netif_init());
    esp_err_t err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
        ESP_ERROR_CHECK(err); 
    }
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL, NULL));

    wifi_config_t wifi_config = {
        .sta = { 
            .ssid = WIFI_SSID, 
            .password = WIFI_PASS 
        },
    };
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());

    // --- ENTSCHEIDENDE OPTIMIERUNGEN FÜR ECHTZEIT-AUDIO ---
    
    // 1. Energiesparmodus KOMPLETT ABSCHALTEN
    // Das hält die RF-Stufe dauerhaft auf Empfang. Ping fällt sofort auf 1-3 ms!
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));
    
    // 2. Wi-Fi Bandbreite auf maximale Performance (HT40 statt standardmäßig HT20)
    // Erhöht den Datendurchsatz und Stabilität bei hoher Paketrate
    ESP_ERROR_CHECK(esp_wifi_set_bandwidth(WIFI_IF_STA, WIFI_BW40));

    ESP_LOGI(TAG, "Wi-Fi Performance-Modus aktiv: Powersave deaktiviert, Bandbreite HT40.");
}

void init_raw_udp_listeners(void) {
    static struct udp_pcb *pcbs[NUM_LISTENERS];
    
    // --- NCO State initialisieren ---
    for(int i = 0; i < NUM_LISTENERS; i++) {
        memset(&channel_buffers[i], 0, sizeof(channel_buffer_t));
        channel_buffers[i].last_sample = 128;
        
        nco_states[i].port = 0;
        nco_states[i].freq_hz = 0;
        nco_states[i].gain = 0;
        current_freq_words[i] = 0;
    }

    // --- Audio RAW Listeners (Ports 1234 - 1243...) ---
    for (int i = 0; i < NUM_LISTENERS; i++) {
        int port = START_PORT + i;
        pcbs[i] = udp_new();
        if (pcbs[i] == NULL) continue;
        
        if (udp_bind(pcbs[i], IP_ANY_TYPE, port) == ERR_OK) {
            udp_recv(pcbs[i], native_udp_recv_callback, NULL);
        } else {
            udp_remove(pcbs[i]);
        }
    }

    // --- Control Listener für Frequenzen (Port 5000) ---
    struct udp_pcb *pcb_freq = udp_new();
    if (pcb_freq != NULL) {
        if (udp_bind(pcb_freq, IP_ANY_TYPE, 5000) == ERR_OK) {
            udp_recv(pcb_freq, control_freq_recv_callback, NULL);
            ESP_LOGI(TAG, "Control-Listener aktiv: Frequenzen (Port 5000)");
        }
    }

    // --- Control Listener für Gain (Port 8888) ---
    struct udp_pcb *pcb_gain = udp_new();
    if (pcb_gain != NULL) {
        if (udp_bind(pcb_gain, IP_ANY_TYPE, 8888) == ERR_OK) {
            udp_recv(pcb_gain, control_gain_recv_callback, NULL);
            ESP_LOGI(TAG, "Control-Listener aktiv: Gain (Port 8888)");
        }
    }
}

void app_main(void) {
    init_gpio_lut(); // initialisiert einmalig die GPIO_LUTs für den optimierten Buszugriff zum FPGA

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

    GPIO.out_w1tc = pin_mask;
    GPIO.out1_w1tc.val = (1ULL << (33-32)) | (1ULL << (32-32));

    esp_task_wdt_config_t wdt_config = {
        .timeout_ms = 10000,
        .idle_core_mask = 0, 
        .trigger_panic = true,
    };
    ESP_ERROR_CHECK(esp_task_wdt_reconfigure(&wdt_config));

    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    wifi_init_sta();
    init_raw_udp_listeners();

    // Der Audio Task läuft auf Core 1!
    xTaskCreatePinnedToCore(audio_task, "audio_task", 4096, NULL, configMAX_PRIORITIES - 1, NULL, 1);

    while (1) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
