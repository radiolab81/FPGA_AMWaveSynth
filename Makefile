# Variablen
VERILATOR = verilator
PYTHON = python3

# Hier das oberste Modul angeben
TOP_MODULE = am_modulator_top

# Automatisch alle .v Dateien im aktuellen Verzeichnis finden
V_SRC = $(wildcard *.v)
CPP_SRC = sim_main.cpp

OBJ_DIR = obj_dir
BIN = $(OBJ_DIR)/V$(TOP_MODULE)

# Name der Sinus-Tabelle (muss mit dem Namen im Verilog-Code übereinstimmen)
LUT_FILE = sin_quarter.hex

# Standard-Ziel: Alles bauen und Simulation starten
all: $(BIN)
	@echo "--- Simulation wird gestartet ---"
	./$(BIN)

# Schritt 1: LUT mit Python generieren
$(LUT_FILE): gen_lut.py
	@echo "--- Generiere Sinus-Tabelle ---"
	@$(PYTHON) gen_lut.py

# Schritt 2: Verilator aufrufen und C++ Binary bauen
# -Wno-fatal: Verhindert Abbruch bei Warnungen
# -Wno-WIDTHTRUNC: Ignoriert Abschneiden von Bits (z.B. bei rf_out)
# -Wno-WIDTHEXPAND: Ignoriert Erweiterung von Port-Breiten (z.B. 11 zu 12 Bit)
# -Wno-UNUSEDSIGNAL: Ignoriert definierte, aber nicht genutzte Register/Wires
$(BIN): $(V_SRC) $(CPP_SRC) $(LUT_FILE)
	@echo "--- Verilator Build-Prozess ---"
	$(VERILATOR) -Wall --cc --exe --build -j 0 --trace \
		-Wno-fatal \
		-Wno-WIDTHTRUNC \
		-Wno-WIDTHEXPAND \
		-Wno-UNUSEDSIGNAL \
		--top-module $(TOP_MODULE) \
		$(CPP_SRC) $(V_SRC)

# Aufräumen
clean:
	rm -rf $(OBJ_DIR) $(LUT_FILE) waveform.vcd dac_output.csv

.PHONY: all clean