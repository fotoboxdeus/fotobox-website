# Fotobox Setup – Schritt-für-Schritt Anleitung

## Voraussetzungen
- Ubuntu 24.04 LTS (frische Installation)
- DNP RX1HS per USB angeschlossen
- Internetverbindung
- GitHub-Account: `fotoboxdeus`

---

## Schritt 1 – Dateien auf den Fotobox-Rechner übertragen

```bash
# Auf dem Fotobox-Rechner:
cd ~
git clone https://github.com/fotoboxdeus/fotobox-website.git fotobox-setup
cd fotobox-setup
```

Oder per USB-Stick: Alle Dateien auf den Rechner kopieren.

---

## Schritt 2 – GitHub Repository anlegen (einmalig)

```bash
# GitHub CLI installieren
sudo apt install gh -y

# Anmelden
gh auth login

# Repository erstellen und Website hochladen
chmod +x create_github_repo.sh
./create_github_repo.sh
```

---

## Schritt 3 – Hauptinstallation ausführen

```bash
chmod +x install.sh
sudo bash install.sh
```

Das Skript installiert und konfiguriert automatisch:
- ✅ CUPS mit 4 Druckerwarteschlangen für DNP RX1HS
- ✅ Avahi/Bonjour für AirPrint
- ✅ nginx Webserver
- ✅ Website von GitHub klonen
- ✅ Chromium im Kiosk-Modus
- ✅ Automatische Starts via systemd
- ✅ Watchdog (Neustart bei Absturz)
- ✅ Stündliche Website-Updates von GitHub

---

## Schritt 4 – Neustart

```bash
sudo reboot
```

Nach dem Neustart startet Chromium automatisch und zeigt `http://localhost`.

---

## Drucker-Übersicht

| Drucker-Name   | Größe | Oberfläche | 2x6-Schnitt |
|----------------|-------|------------|-------------|
| RX1 4x6 Matt   | 4x6"  | Matt       | –           |
| RX1 4x6 Gloss  | 4x6"  | Glanz      | –           |
| RX1 2x6 Matt   | 2x6"  | Matt       | ✅           |
| RX1 2x6 Gloss  | 2x6"  | Glanz      | ✅           |

Alle Drucker sind über **AirPrint** im lokalen Netzwerk erreichbar.

---

## Dienste verwalten

```bash
# Status aller Dienste
sudo systemctl status cups nginx fotobox-kiosk fotobox-update.timer

# Kiosk-Browser neu starten
sudo systemctl restart fotobox-kiosk

# CUPS-Weboberfläche (lokal)
# → http://localhost:631

# Website manuell von GitHub aktualisieren
sudo systemctl start fotobox-update.service

# nginx neu laden (nach Website-Änderungen)
sudo systemctl reload nginx
```

---

## DNP-Treiber manuell nachinstallieren (falls nötig)

Falls die automatische Erkennung fehlschlägt:

1. PPD von [dnpphoto.eu](https://www.dnpphoto.eu/drivers) herunterladen
2. PPD nach `/usr/share/cups/model/` kopieren:
   ```bash
   sudo cp DNP_RX1HS.ppd /usr/share/cups/model/
   sudo systemctl restart cups
   ```
3. Drucker manuell anlegen:
   ```bash
   sudo lpadmin -p "RX1_4x6_Matt" -D "RX1 4x6 Matt" \
     -v "usb://DNP/RX1HS" \
     -P /usr/share/cups/model/DNP_RX1HS.ppd \
     -o PageSize=w288h432 -o StpFinish=Matte -E
   ```

---

## Website anpassen

Die Website liegt in `website/`:
- `index.html` – Hauptseite
- `style.css`  – Design
- `app.js`     – Logik

Änderungen auf GitHub pushen → automatisch auf Fotobox eingespielt (stündlich).
