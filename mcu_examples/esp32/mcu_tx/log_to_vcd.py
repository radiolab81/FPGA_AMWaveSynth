import re

def convert_memory_log_to_vcd(log_filename, vcd_filename):
    print(f"Konvertiere {log_filename} nach {vcd_filename}...")
    
    # Angepasste Regex für Ihr exaktes Log-Format (ohne führenden Timestamp)
    # Matcht: memory_region_ops_write ... addr 0x3ff4400c value 0x40000 ...
    memory_pattern = re.compile(r'memory_region_ops_write.*addr\s(0x[0-9a-fA-F]+)\svalue\s(0x[0-9a-fA-F]+)')
    
    # ESP32 GPIO Register-Adressen (Untere Pins 0-31)
    GPIO_OUT_REG       = 0x3ff44004
    GPIO_OUT_W1TS_REG  = 0x3ff44008
    GPIO_OUT_W1TC_REG  = 0x3ff4400c

    # ESP32 GPIO Register-Adressen (Obere Pins 32-39)
    GPIO_OUT1_REG      = 0x3ff44014
    GPIO_OUT1_W1TS_REG = 0x3ff44018
    GPIO_OUT1_W1TC_REG = 0x3ff4401c

    try:
        with open(log_filename, 'r') as log, open(vcd_filename, 'w') as vcd:
            # VCD Header für alle 40 Pins generieren
            vcd.write("$date\n  Today\n$end\n$version\n  QEMU ESP32 MMIO GPIO Converter v2\n$end\n$timescale 1ns $end\n")
            vcd.write("$scope module esp32_gpios $end\n")
            for pin in range(40):
                vcd.write(f"$var wire 1 g{pin} GPIO_{pin} $end\n")
            vcd.write("$upscope $end\n$enddefinitions $end\n")
            
            # Startzustand (Alle 40 Pins auf 0)
            vcd.write("#0\n")
            for pin in range(40):
                vcd.write(f"0g{pin}\n")
                
            # Wir nutzen die Zeilennummer als künstliche Zeitachse, da kein nativer Timestamp im Log ist
            virtual_timestamp = 1
            
            # Zustandsspeicher für beide Register-Bänke
            state_low = 0   # Pins 0-31
            state_high = 0  # Pins 32-39
            count = 0
            
            for line in log:
                match = memory_pattern.search(line)
                if match:
                    addr = int(match.group(1), 16)
                    val = int(match.group(2), 16)
                    
                    next_low = state_low
                    next_high = state_high
                    is_gpio_event = False
                    
                    # Logik für Pins 0-31
                    if addr == GPIO_OUT_REG:
                        next_low = val
                        is_gpio_event = True
                    elif addr == GPIO_OUT_W1TS_REG:
                        next_low |= val
                        is_gpio_event = True
                    elif addr == GPIO_OUT_W1TC_REG:
                        next_low &= ~val
                        is_gpio_event = True
                        
                    # Logik für Pins 32-39
                    elif addr == GPIO_OUT1_REG:
                        next_high = val & 0xFF  # Nur die unteren 8 Bit sind gültig
                        is_gpio_event = True
                    elif addr == GPIO_OUT1_W1TS_REG:
                        next_high |= (val & 0xFF)
                        is_gpio_event = True
                    elif addr == GPIO_OUT1_W1TC_REG:
                        next_high &= ~(val & 0xFF)
                        is_gpio_event = True
                    
                    # Wenn es ein GPIO-Event war und sich Werte geändert haben
                    if is_gpio_event and (next_low != state_low or next_high != state_high):
                        vcd.write(f"#{virtual_timestamp}\n")
                        
                        # Flankenwechsel für Pins 0-31 prüfen
                        if next_low != state_low:
                            for pin in range(32):
                                old_bit = (state_low >> pin) & 1
                                new_bit = (next_low >> pin) & 1
                                if old_bit != new_bit:
                                    vcd.write(f"{new_bit}g{pin}\n")
                            state_low = next_low
                            
                        # Flankenwechsel für Pins 32-39 prüfen
                        if next_high != state_high:
                            for pin in range(8):
                                old_bit = (state_high >> pin) & 1
                                new_bit = (next_high >> pin) & 1
                                if old_bit != new_bit:
                                    vcd.write(f"{new_bit}g{32 + pin}\n")
                            state_high = next_high
                            
                        count += 1
                        
                # Jede verarbeitete Logzeile inkrementiert die Zeit um 1ns
                virtual_timestamp += 1
                        
            print(f"Erfolgreich konvertiert! {count} GPIO-Änderungen in VCD geschrieben.")
            
    except FileNotFoundError:
        print(f"Fehler: '{log_filename}' wurde nicht gefunden.")

if __name__ == "__main__":
    convert_memory_log_to_vcd("qemu_gpio_trace.log", "output.vcd")
