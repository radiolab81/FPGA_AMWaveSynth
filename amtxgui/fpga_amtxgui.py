import tkinter as tk
from tkinter import ttk, messagebox, filedialog
import csv, os, re, subprocess, stat

# --- Lokalisierungs-Daten ---
LANGUAGES = {
    "DE": {
        "win_title": "FPGA - AM Transmission Multi-Stream Control",
        "col_freq": "Frequenz", "col_bw": "Bandbreite", "col_name": "Programmname", "col_url": "URL",
        "btn_start": "ALLE Sender STARTEN", "btn_stop": "ALLE Sender STOPPEN",
        "status_label": "Modulator Status:",
        "menu_file": "Datei", "menu_load": "Laden", "menu_save": "Speichern",
        "menu_sender": "Sender", "menu_add": "Hinzufügen", "menu_del": "Entfernen",
        "menu_lang": "Sprache", "dlg_title": "Sender-Parameter",
        "dlg_plan": "Frequenzplan:", "dlg_freq": "Frequenz:", "dlg_bw": "Audiobandbreite:",
        "dlg_prog": "Programm wählen:", "dlg_url": "Programm-URL:", "dlg_btn": "Hinzufügen",
        "err_freq": "Frequenz belegt!", "err_title": "Fehler"
    },
    "EN": {
        "win_title": "FPGA - AM Transmission Multi-Stream Control",
        "col_freq": "Frequency", "col_bw": "Bandwidth", "col_name": "Program Name", "col_url": "URL",
        "btn_start": "START ALL STATIONS", "btn_stop": "STOP ALL STATIONS",
        "status_label": "Modulator Status:",
        "menu_file": "File", "menu_load": "Load", "menu_save": "Save",
        "menu_sender": "Station", "menu_add": "Add", "menu_del": "Remove",
        "menu_lang": "Language", "dlg_title": "Station Parameters",
        "dlg_plan": "Frequency Plan:", "dlg_freq": "Frequency:", "dlg_bw": "Audio Bandwidth:",
        "dlg_prog": "Select Program:", "dlg_url": "Program URL:", "dlg_btn": "Add",
        "err_freq": "Frequency occupied!", "err_title": "Error"
    },
    "FR": {
        "win_title": "FPGA - AM Transmission Multi-Stream Control",
        "col_freq": "Fréquence", "col_bw": "Bande passante", "col_name": "Nom du programme", "col_url": "URL",
        "btn_start": "DÉMARRER TOUS LES ÉMETTEURS", "btn_stop": "ARRÊTER TOUS LES ÉMETTEURS",
        "status_label": "Statut du modulateur:",
        "menu_file": "Fichier", "menu_load": "Charger", "menu_save": "Enregistrer",
        "menu_sender": "Émetteur", "menu_add": "Ajouter", "menu_del": "Supprimer",
        "menu_lang": "Langue", "dlg_title": "Paramètres de l'émetteur",
        "dlg_plan": "Plan de fréquences :", "dlg_freq": "Fréquence :", "dlg_bw": "Bande passante audio :",
        "dlg_prog": "Choisir le programme :", "dlg_url": "URL du programme :", "dlg_btn": "Ajouter",
        "err_freq": "Fréquence occupée !", "err_title": "Erreur"
    },
    "IT": {
        "win_title": "FPGA - AM Transmission Multi-Stream Control",
        "col_freq": "Frequenza", "col_bw": "Larghezza di banda", "col_name": "Nome programma", "col_url": "URL",
        "btn_start": "AVVIA TUTTE LE STAZIONI", "btn_stop": "FERMA TUTTE LE STAZIONI",
        "status_label": "Stato modulatore:",
        "menu_file": "File", "menu_load": "Carica", "menu_save": "Salva",
        "menu_sender": "Stazione", "menu_add": "Aggiungi", "menu_del": "Rimuovi",
        "menu_lang": "Lingua", "dlg_title": "Parametri della stazione",
        "dlg_plan": "Piano di frequenza:", "dlg_freq": "Frequenza:", "dlg_bw": "Larghezza di banda audio:",
        "dlg_prog": "Seleziona programma:", "dlg_url": "URL del programma:", "dlg_btn": "Aggiungi",
        "err_freq": "Frequenza occupata!", "err_title": "Errore"
    },
    "JA": {
        "win_title": "FPGA - AMマルチストリーム送信制御",
        "col_freq": "周波数", "col_bw": "帯域幅", "col_name": "番組名", "col_url": "URL",
        "btn_start": "全送信機を開始", "btn_stop": "全送信機を停止",
        "status_label": "変調器ステータス:",
        "menu_file": "ファイル", "menu_load": "読み込み", "menu_save": "保存",
        "menu_sender": "送信局", "menu_add": "追加", "menu_del": "削除",
        "menu_lang": "言語 (Language)", "dlg_title": "送信パラメータ",
        "dlg_plan": "周波数プラン:", "dlg_freq": "周波数:", "dlg_bw": "音声帯域幅:",
        "dlg_prog": "番組を選択:", "dlg_url": "番組URL:", "dlg_btn": "追加",
        "err_freq": "周波数が重複しています！", "err_title": "エラー"
    }
}

class SenderDialog(tk.Toplevel):
    def __init__(self, parent, station_db, existing_frequencies, lang_code="DE", initial_values=None):
        super().__init__(parent)
        self.lang = LANGUAGES[lang_code]
        self.title(self.lang["dlg_title"])
        self.geometry("480x230")
        self.station_db, self.existing_frequencies = station_db, existing_frequencies
        self.result = None
        self.transient(parent); self.wait_visibility(); self.grab_set()

        self.plans = {
            "Europa (9 kHz Raster)": [f"{f} kHz" for f in range(153, 280, 9)] + [f"{f} kHz" for f in range(531, 1603, 9)],
            "USA (10 kHz Raster)": [f"{f} kHz" for f in range(530, 1710, 10)],
            "CH HF-Telefonrundspruch": ["175 kHz", "208 kHz", "241 kHz", "274 kHz", "307 kHz", "340 kHz"],
            "IT Filodiffusione (RAI)": ["178 kHz", "211 kHz", "244 kHz", "277 kHz", "310 kHz", "343 kHz"],
            "Manuelle Eingabe": []
        }
        self.bw_values = ["4.5 kHz", "5.0 kHz", "6.0 kHz", "7.0 kHz", "9.0 kHz", "10.0 kHz", "12.0 kHz"]

        fields = [(self.lang["dlg_plan"], "plan"), (self.lang["dlg_freq"], "freq"), 
                  (self.lang["dlg_bw"], "bw"), (self.lang["dlg_prog"], "name"), (self.lang["dlg_url"], "url")]
        self.widgets = {}
        for i, (label, key) in enumerate(fields):
            tk.Label(self, text=label).grid(row=i, column=0, padx=10, pady=5, sticky="w")
            if key == "plan":
                w = ttk.Combobox(self, values=list(self.plans.keys()), state="readonly", width=35)
                w.set("Europa (9 kHz Raster)"); w.bind("<<ComboboxSelected>>", self.update_freq_list)
            elif key == "freq" or key == "bw":
                w = ttk.Combobox(self, width=35)
                if key == "bw": w['values'] = self.bw_values; w.set("4.5 kHz")
            elif key == "name":
                w = ttk.Combobox(self, values=sorted(list(self.station_db.keys())), width=35)
                w.bind("<<ComboboxSelected>>", self.autofill_url)
            else:
                w = tk.Entry(self, width=38)
            w.grid(row=i, column=1, padx=10, pady=5); self.widgets[key] = w

        self.update_freq_list()

        if initial_values:
            self.widgets['plan'].set("Manuelle Eingabe") # Verhindert das Überschreiben der Combobox
            self.widgets['freq'].set(initial_values[0])
            self.widgets['bw'].set(initial_values[1])
            self.widgets['name'].set(initial_values[2])
            self.widgets['url'].delete(0, tk.END)
            self.widgets['url'].insert(0, initial_values[3])

        tk.Button(self, text=self.lang["dlg_btn"], command=self.confirm, bg="#d5e8d4").grid(row=5, column=0, columnspan=2, pady=20)

    def update_freq_list(self, e=None):
        vals = self.plans[self.widgets['plan'].get()]
        self.widgets['freq']['values'] = vals
        if vals: self.widgets['freq'].set(vals)

    def autofill_url(self, e=None):
        name = self.widgets['name'].get()
        if name in self.station_db:
            self.widgets['url'].delete(0, tk.END); self.widgets['url'].insert(0, self.station_db[name])

    def confirm(self):
        res = [self.widgets['freq'].get(), self.widgets['bw'].get(), self.widgets['name'].get(), self.widgets['url'].get()]
        if any(f in res[0] for f in self.existing_frequencies):
            messagebox.showerror(self.lang["err_title"], self.lang["err_freq"]); return
        if all(x.strip() for x in res): self.result = res; self.destroy()

class RadioApp:
    def __init__(self, root):
        self.root = root
        self.current_lang = "DE"
        self.base_dir = os.path.dirname(os.path.abspath(__file__))
        self.station_db = self.load_stations_db()
        self.main_proc = None

        # Tabelle
        self.tree = ttk.Treeview(root, show='headings')
        self.tree.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)

        # Erweiterung: Doppelklick-Binding zum Bearbeiten
        self.tree.bind("<Double-1>", self.edit_entry)

        # Button & Ampel Panel
        btn_panel = tk.Frame(root)
        btn_panel.pack(fill=tk.X, padx=10, pady=10)
        
        self.btn_start = tk.Button(btn_panel, bg="#90ee90", command=self.start_all, width=25, height=2)
        self.btn_start.pack(side=tk.LEFT, padx=5)
        self.btn_stop = tk.Button(btn_panel, bg="#ffcccb", command=self.stop_all, width=25, height=2)
        self.btn_stop.pack(side=tk.LEFT, padx=5)

        # Ampel Sektion
        ampel_frame = tk.Frame(btn_panel)
        ampel_frame.pack(side=tk.RIGHT, padx=20)
        self.lbl_status = tk.Label(ampel_frame, font=("Arial", 10))
        self.lbl_status.pack(side=tk.LEFT)
        self.ampel = tk.Canvas(ampel_frame, width=30, height=30, highlightthickness=0)
        self.ampel_light = self.ampel.create_oval(5, 5, 25, 25, fill="red")
        self.ampel.pack(side=tk.LEFT, padx=5)

        # Menü initialisieren
        self.menubar = tk.Menu(root)
        self.root.config(menu=self.menubar)
        
        # UI Initialisierung
        self.update_ui_language()
        self.check_status()

    def update_ui_language(self):
        lang = LANGUAGES[self.current_lang]
        self.root.title(lang["win_title"])
        
        # Tabelle Header
        self.tree["columns"] = ("Frequenz", "Bandbreite", "Programmname", "URL")
        for col, text_key in zip(self.tree["columns"], ["col_freq", "col_bw", "col_name", "col_url"]):
            self.tree.heading(col, text=lang[text_key])
            self.tree.column(col, width=400 if col=="URL" else 110)

        # Buttons & Labels
        self.btn_start.config(text=lang["btn_start"])
        self.btn_stop.config(text=lang["btn_stop"])
        self.lbl_status.config(text=lang["status_label"])

        # Menü neu aufbauen
        self.menubar.delete(0, tk.END)
        
        file_menu = tk.Menu(self.menubar, tearoff=0)
        file_menu.add_command(label=lang["menu_load"], command=self.load_csv)
        file_menu.add_command(label=lang["menu_save"], command=self.save_csv)
        self.menubar.add_cascade(label=lang["menu_file"], menu=file_menu)

        sender_menu = tk.Menu(self.menubar, tearoff=0)
        sender_menu.add_command(label=lang["menu_add"], command=self.add_entry)
        sender_menu.add_command(label=lang["menu_del"], command=self.delete_entry)
        self.menubar.add_cascade(label=lang["menu_sender"], menu=sender_menu)

        lang_menu = tk.Menu(self.menubar, tearoff=0)
        lang_menu.add_command(label="Deutsch", command=lambda: self.set_language("DE"))
        lang_menu.add_command(label="English", command=lambda: self.set_language("EN"))
        lang_menu.add_command(label="Français", command=lambda: self.set_language("FR"))
        lang_menu.add_command(label="Italiano", command=lambda: self.set_language("IT"))
        lang_menu.add_command(label="日本語", command=lambda: self.set_language("JA"))
        self.menubar.add_cascade(label=lang["menu_lang"], menu=lang_menu)

    def set_language(self, code):
        self.current_lang = code
        self.update_ui_language()

    def check_status(self):
        try:
            result = subprocess.run(["pgrep", "ffmpeg"], capture_output=True)
            color = "lime" if result.returncode == 0 else "red"
            self.ampel.itemconfig(self.ampel_light, fill=color)
        except:
            self.ampel.itemconfig(self.ampel_light, fill="gray")
        self.root.after(1000, self.check_status)

    def load_stations_db(self):
        db = {}
        path = os.path.join(self.base_dir, "stations.db")
        if os.path.exists(path):
            with open(path, "r") as f:
                r = csv.reader(f)
                for row in r: 
                    if len(row)>=2: db[row[0].strip()] = row[1].strip()
        return db

    def clean(self, v):
        m = re.search(r"(\d+(\.\d+)?)", str(v))
        return m.group(1) if m else "0"

    def add_entry(self):
        exist = [str(self.tree.set(k, "Frequenz")) for k in self.tree.get_children()]
        d = SenderDialog(self.root, self.station_db, exist, self.current_lang); self.root.wait_window(d)
        if d.result:
            self.tree.insert("", tk.END, values=d.result)
            items = [(float(self.clean(self.tree.set(k, "Frequenz"))), k) for k in self.tree.get_children()]
            items.sort(); [self.tree.move(k, '', i) for i, (v, k) in enumerate(items)]

    def edit_entry(self, event=None):
        selected = self.tree.selection()
        if not selected: return
        
        item_id = selected[0]
        current_values = self.tree.item(item_id, 'values')
        
        # Alle existierenden Frequenzen holen, ABER die des aktuellen Eintrags ignorieren
        exist = [str(self.tree.set(k, "Frequenz")) for k in self.tree.get_children() if k != item_id]
        
        # Dialog mit aktuellen Werten öffnen
        d = SenderDialog(self.root, self.station_db, exist, self.current_lang, initial_values=current_values)
        self.root.wait_window(d)
        
        # Falls bestätigt wurde, Daten überschreiben und neu sortieren
        if d.result:
            self.tree.item(item_id, values=d.result)
            items = [(float(self.clean(self.tree.set(k, "Frequenz"))), k) for k in self.tree.get_children()]
            items.sort()
            [self.tree.move(k, '', i) for i, (v, k) in enumerate(items)]

    def delete_entry(self):
        for i in self.tree.selection(): self.tree.delete(i)

    def start_all(self):
        if self.main_proc: self.stop_all()
        args = []
        port = 1234
        for k in self.tree.get_children():
            v = self.tree.item(k)['values']
            args.extend([self.clean(v[0]), self.clean(v[1]), f'"{v[3]}"', str(port)])
            port += 1
        if not args: return
        script = os.path.join(self.base_dir, "start_sender.sh")
        cmd_str = f"/bin/bash '{script}' {' '.join(args)}"
        try:
            self.main_proc = subprocess.Popen(["xterm", "-T", "AM-Broadcaster", "-e", "/bin/bash", "-c", cmd_str])
            #subprocess.Popen(["xterm", "-T", "fl2k_tcp DAC Transfer", "-e", "/bin/bash", "-c", "sudo ./start_fl2k.sh"])
        except Exception as e: messagebox.showerror(LANGUAGES[self.current_lang]["err_title"], str(e))

    def stop_all(self):
        if self.main_proc:
            stop_script = os.path.join(self.base_dir, "stop_sender.sh")
            subprocess.run(["/bin/bash", stop_script, str(self.main_proc.pid)])
            self.main_proc.terminate(); self.main_proc = None

    def save_csv(self):
        p = filedialog.asksaveasfilename(defaultextension=".csv",filetypes=(("CSV Files", "*.csv"),))
        if p:
            with open(p, 'w', newline='', encoding='utf-8') as f:
                w = csv.writer(f, delimiter=';')
                w.writerow([LANGUAGES[self.current_lang][k] for k in ["col_freq", "col_bw", "col_name", "col_url"]])
                for k in self.tree.get_children(): w.writerow(self.tree.item(k)['values'])

    def load_csv(self):
        p = filedialog.askopenfilename(
    	filetypes=(("CSV Files", "*.csv"),)
	)
        if p:
            for i in self.tree.get_children(): self.tree.delete(i)
            with open(p, 'r', encoding='utf-8') as f:
                r = csv.reader(f, delimiter=';'); next(r)
                for row in r: self.tree.insert("", tk.END, values=row)

if __name__ == "__main__":
    root = tk.Tk()
    app = RadioApp(root)
    root.mainloop()
