#!/bin/bash
# =============================================================================
# Fotobox Setup Script
# Ziel: Ubuntu 24.04+ | DNP RX1HS | CUPS | nginx | Chromium Kiosk
# GitHub: github.com/fotoboxdeus/fotobox-website
# =============================================================================
set -euo pipefail

# --- Farben ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Root-Check ---
if [[ $EUID -ne 0 ]]; then
  error "Dieses Skript muss als root ausgeführt werden: sudo bash install.sh"
fi

KIOSK_USER="${SUDO_USER:-fotobox}"
WEBROOT="/var/www/fotobox"
GITHUB_REPO="https://github.com/fotoboxdeus/fotobox-website.git"
SITE_URL="http://localhost"

log "Starte Fotobox-Installation für Benutzer: $KIOSK_USER"

# =============================================================================
# 1. SYSTEM-UPDATE & PAKETE
# =============================================================================
log "System wird aktualisiert..."
apt-get update -qq
apt-get upgrade -y -qq

log "Installiere benötigte Pakete..."
apt-get install -y \
  cups \
  cups-client \
  cups-filters \
  printer-driver-gutenprint \
  avahi-daemon \
  nginx \
  git \
  chromium-browser \
  openbox \
  xdotool \
  unclutter \
  curl \
  wget \
  jq

# =============================================================================
# 2. CUPS – Installation & Konfiguration
# =============================================================================
log "Konfiguriere CUPS..."

# CUPS-Konfiguration: AirPrint / Netzwerkzugriff aktivieren
cat > /etc/cups/cupsd.conf << 'CUPSCONF'
LogLevel warn
MaxLogSize 0
ErrorPolicy retry-job

# Nur localhost und lokales Netz
Listen localhost:631
Listen /run/cups/cups.sock

# Freigegebene Drucker über Bonjour/AirPrint
Browsing Yes
BrowseLocalProtocols dnssd
DefaultAuthType Basic

<Location />
  Order allow,deny
  Allow localhost
</Location>

<Location /admin>
  Order allow,deny
  Allow localhost
</Location>

<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow localhost
</Location>

<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default

  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order deny,allow
  </Limit>

  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Pause-Printer Resume-Printer Enable-Printer Disable-Printer Pause-Printer-After-Current-Job Hold-New-Jobs Release-Held-New-Jobs Deactivate-Printer Activate-Printer Restart-Printer Shutdown-Printer Startup-Printer Promote-Job Schedule-Job-After Cancel-Jobs CUPS-Accept-Jobs CUPS-Reject-Jobs>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>

  <Limit Cancel-Job CUPS-Authenticate-Job>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>

  <Limit All>
    Order deny,allow
  </Limit>
</Policy>
CUPSCONF

# CUPS-Benutzer in lpadmin aufnehmen
usermod -aG lpadmin "$KIOSK_USER" 2>/dev/null || true

# CUPS starten
systemctl enable cups
systemctl restart cups
sleep 2

# =============================================================================
# 3. DNP RX1HS PPD-DATEI INSTALLIEREN
# =============================================================================
log "Installiere DNP RX1HS PPD-Datei..."

# PPD liegt im selben Verzeichnis wie dieses Skript
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PPD="$SCRIPT_DIR/DNP.ppd"
DNP_PPD="/usr/share/cups/model/DNP_RX1HS.ppd"
USE_GUTENPRINT_URI=0

if [[ ! -f "$SRC_PPD" ]]; then
  error "DNP.ppd nicht gefunden in $SCRIPT_DIR – bitte sicherstellen, dass die Datei neben install.sh liegt."
fi

cp "$SRC_PPD" "$DNP_PPD"
chmod 644 "$DNP_PPD"
log "PPD installiert nach: $DNP_PPD"

# =============================================================================
# 4. DRUCKER ANLEGEN (DNP RX1HS – 4 Warteschlangen)
# =============================================================================
log "Lege CUPS-Drucker an..."

# Hilfsfunktion: Drucker anlegen
add_printer() {
  local NAME="$1"
  local DESC="$2"
  local MEDIA="$3"       # z.B. w144h432 (2x6) oder w288h432 (4x6)
  local FINISH="$4"      # Glossy oder Matte
  local CUT="$5"         # "" oder "2x6" für 2x6-Schnitt

  log "  → Erstelle Drucker: $NAME"

  # Drucker entfernen falls vorhanden
  lpadmin -x "$NAME" 2>/dev/null || true

  lpadmin \
    -p "$NAME" \
    -D "$DESC" \
    -L "Fotobox" \
    -v "usb://DNP/RX1HS" \
    -P "$DNP_PPD" \
    -o PageSize="$MEDIA" \
    -o StpFinish="$FINISH" \
    -E

  # Drucker als Standard freigeben & aktivieren
  cupsenable "$NAME"
  cupsaccept "$NAME"

  # 2x6-Schnitt aktivieren falls gewünscht
  if [[ "$CUT" == "2x6" ]]; then
    lpadmin -p "$NAME" -o StpCut=Cut2x6 2>/dev/null || \
    lpadmin -p "$NAME" -o Duplex=None 2>/dev/null || true
    log "    2x6-Schnitt aktiviert"
  fi

  # AirPrint-Sharing aktivieren
  lpadmin -p "$NAME" -o printer-is-shared=true

  log "  ✓ $NAME angelegt"
}

# --- 4x6 Drucker ---
# Mediasize: w288h432 = 4x6 Zoll in 1/100 mm
add_printer "RX1_4x6_Matt"  "RX1 4x6 Matt"  "w288h432" "Matte"  ""
add_printer "RX1_4x6_Gloss" "RX1 4x6 Gloss" "w288h432" "Glossy" ""

# --- 2x6 Drucker ---
# Mediasize: w144h432 = 2x6 Zoll (Streifen)
add_printer "RX1_2x6_Matt"  "RX1 2x6 Matt"  "w144h432" "Matte"  "2x6"
add_printer "RX1_2x6_Gloss" "RX1 2x6 Gloss" "w144h432" "Glossy" "2x6"

# CUPS neu laden damit AirPrint-Bekanntmachung startet
systemctl restart cups

# =============================================================================
# 5. AVAHI (BONJOUR / AIRPRINT)
# =============================================================================
log "Konfiguriere Avahi für AirPrint..."

systemctl enable avahi-daemon
systemctl restart avahi-daemon

# CUPS-Browsing via DNS-SD sicherstellen
if ! grep -q "dnssd" /etc/cups/cupsd.conf; then
  sed -i 's/BrowseLocalProtocols .*/BrowseLocalProtocols dnssd/' /etc/cups/cupsd.conf
  systemctl restart cups
fi

log "AirPrint-Drucker sind im Netzwerk sichtbar."

# =============================================================================
# 6. NGINX – WEBSERVER
# =============================================================================
log "Konfiguriere nginx..."

# Webroot anlegen
mkdir -p "$WEBROOT"
chown -R www-data:www-data "$WEBROOT"

# nginx-Site-Konfiguration
cat > /etc/nginx/sites-available/fotobox << NGINXCONF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root $WEBROOT;
    index index.html index.htm;

    server_name localhost;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Statische Assets cachen
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
        expires 7d;
        add_header Cache-Control "public, immutable";
    }

    # Kein Cache für HTML
    location ~* \.html$ {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    access_log /var/log/nginx/fotobox_access.log;
    error_log  /var/log/nginx/fotobox_error.log;
}
NGINXCONF

# Default-Site deaktivieren, Fotobox-Site aktivieren
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/fotobox /etc/nginx/sites-enabled/fotobox

nginx -t || error "nginx-Konfiguration fehlerhaft!"

systemctl enable nginx
systemctl restart nginx

# =============================================================================
# 7. WEBSITE VON GITHUB KLONEN
# =============================================================================
log "Klone Website von GitHub: $GITHUB_REPO"

if [[ -d "$WEBROOT/.git" ]]; then
  log "Repository existiert bereits, führe git pull aus..."
  git -C "$WEBROOT" pull --ff-only
else
  # Webroot leeren und frisch klonen
  rm -rf "$WEBROOT"
  git clone "$GITHUB_REPO" "$WEBROOT" || {
    warn "GitHub-Repo konnte nicht geklont werden."
    warn "Erstelle Platzhalter-Website..."
    mkdir -p "$WEBROOT"
    cat > "$WEBROOT/index.html" << 'HTML'
<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Fotobox</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: #1a1a2e;
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100vh;
      font-family: 'Segoe UI', sans-serif;
      color: #eee;
      overflow: hidden;
    }
    .container { text-align: center; }
    h1 { font-size: 4rem; letter-spacing: 0.2em; margin-bottom: 1rem; }
    p  { font-size: 1.2rem; opacity: 0.7; }
  </style>
</head>
<body>
  <div class="container">
    <h1>📸 FOTOBOX</h1>
    <p>Bereit zum Fotografieren</p>
  </div>
</body>
</html>
HTML
  }
fi

chown -R www-data:www-data "$WEBROOT"

# =============================================================================
# 8. AUTO-UPDATE SERVICE (Website von GitHub)
# =============================================================================
log "Erstelle Auto-Update-Service für Website..."

cat > /etc/systemd/system/fotobox-update.service << 'SVC'
[Unit]
Description=Fotobox Website Auto-Update von GitHub
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/git -C /var/www/fotobox pull --ff-only
ExecStartPost=/bin/chown -R www-data:www-data /var/www/fotobox
User=root
SVC

cat > /etc/systemd/system/fotobox-update.timer << 'TMR'
[Unit]
Description=Fotobox Website stündlich aktualisieren

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable fotobox-update.timer
systemctl start fotobox-update.timer

# =============================================================================
# 9. CHROMIUM KIOSK – SYSTEMD-SERVICE
# =============================================================================
log "Konfiguriere Chromium-Kiosk-Modus..."

# Xauthority-Pfad für den Kiosk-Benutzer
KIOSK_HOME=$(eval echo "~$KIOSK_USER")

# Kiosk-Startskript
cat > /usr/local/bin/fotobox-kiosk.sh << KIOSK
#!/bin/bash
# Warte bis X-Server verfügbar ist
for i in \$(seq 1 30); do
  if xdpyinfo -display :0 &>/dev/null 2>&1; then break; fi
  sleep 1
done

export DISPLAY=:0
export XAUTHORITY="$KIOSK_HOME/.Xauthority"

# Mauszeiger ausblenden
unclutter -idle 1 -root &

# Chromium im Kiosk-Modus starten
exec chromium-browser \
  --kiosk \
  --noerrdialogs \
  --disable-infobars \
  --no-first-run \
  --disable-translate \
  --disable-features=TranslateUI \
  --disable-component-update \
  --disable-background-networking \
  --check-for-update-interval=31536000 \
  --disable-session-crashed-bubble \
  --disable-restore-session-state \
  --autoplay-policy=no-user-gesture-required \
  --start-fullscreen \
  "$SITE_URL"
KIOSK

chmod +x /usr/local/bin/fotobox-kiosk.sh

# Systemd-Service für Chromium (startet nach GDM/GNOME)
cat > /etc/systemd/system/fotobox-kiosk.service << SVC
[Unit]
Description=Fotobox Chromium Kiosk
After=graphical.target network-online.target
Wants=network-online.target
Requires=graphical.target

[Service]
Type=simple
User=$KIOSK_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=$KIOSK_HOME/.Xauthority
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/fotobox-kiosk.sh
Restart=always
RestartSec=5
KillMode=process

[Install]
WantedBy=graphical.target
SVC

systemctl daemon-reload
systemctl enable fotobox-kiosk.service

# =============================================================================
# 10. WATCHDOG – Alle Dienste überwachen
# =============================================================================
log "Konfiguriere systemd-Watchdog für alle Dienste..."

# nginx Watchdog
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/restart.conf << 'CONF'
[Service]
Restart=always
RestartSec=5
CONF

# CUPS Watchdog
mkdir -p /etc/systemd/system/cups.service.d
cat > /etc/systemd/system/cups.service.d/restart.conf << 'CONF'
[Service]
Restart=always
RestartSec=5
CONF

# Avahi Watchdog
mkdir -p /etc/systemd/system/avahi-daemon.service.d
cat > /etc/systemd/system/avahi-daemon.service.d/restart.conf << 'CONF'
[Service]
Restart=always
RestartSec=5
CONF

systemctl daemon-reload

# =============================================================================
# 11. AUTOSTART IM GNOME-MODUS (als Fallback für GNOME-Session)
# =============================================================================
log "Konfiguriere GNOME-Autostart für Chromium-Kiosk..."

AUTOSTART_DIR="$KIOSK_HOME/.config/autostart"
mkdir -p "$AUTOSTART_DIR"
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config" 2>/dev/null || true

cat > "$AUTOSTART_DIR/fotobox-kiosk.desktop" << DESKTOP
[Desktop Entry]
Type=Application
Name=Fotobox Kiosk
Exec=/usr/local/bin/fotobox-kiosk.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
DESKTOP

chown "$KIOSK_USER:$KIOSK_USER" "$AUTOSTART_DIR/fotobox-kiosk.desktop"

# Automatische Anmeldung in GDM konfigurieren
log "Konfiguriere automatische GNOME-Anmeldung für $KIOSK_USER..."

GDM_CONF="/etc/gdm3/custom.conf"
if [[ -f "$GDM_CONF" ]]; then
  # Automatische Anmeldung setzen
  sed -i '/^\[daemon\]/,/^\[/{
    /AutomaticLoginEnable/d
    /AutomaticLogin=/d
  }' "$GDM_CONF"

  sed -i '/^\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin='"$KIOSK_USER" "$GDM_CONF"
  log "  Automatische Anmeldung aktiviert für: $KIOSK_USER"
else
  warn "GDM-Konfiguration nicht gefunden unter $GDM_CONF"
fi

# =============================================================================
# 12. ABSCHLUSS
# =============================================================================
log ""
log "============================================================"
log " INSTALLATION ABGESCHLOSSEN"
log "============================================================"
log ""
log " Drucker (via CUPS / AirPrint):"
log "   ✓ RX1 4x6 Matt   → 4x6 Zoll, matte Oberfläche"
log "   ✓ RX1 4x6 Gloss  → 4x6 Zoll, glänzende Oberfläche"
log "   ✓ RX1 2x6 Matt   → 2x6 Zoll, matt, mit 2x6-Schnitt"
log "   ✓ RX1 2x6 Gloss  → 2x6 Zoll, glänzend, mit 2x6-Schnitt"
log ""
log " Webserver:  nginx auf http://localhost"
log " Website:    $WEBROOT (von GitHub)"
log " Kiosk:      Chromium startet automatisch nach Login"
log ""
log " WICHTIG – Nächste Schritte:"
log " 1. DNP RX1HS per USB anschließen (vor Neustart)"
log " 2. Druckertreiber prüfen: http://localhost:631"
log " 3. GitHub-Repo 'fotoboxdeus/fotobox-website' erstellen"
log "    (Skript: ./create_github_repo.sh)"
log " 4. System neu starten: sudo reboot"
log ""
log " Service-Status prüfen:"
log "   sudo systemctl status cups"
log "   sudo systemctl status nginx"
log "   sudo systemctl status fotobox-kiosk"
log "   sudo systemctl status fotobox-update.timer"
log "============================================================"
