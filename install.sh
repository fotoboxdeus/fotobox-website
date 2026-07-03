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
REPO_DIR="/opt/fotobox-repo"          # Komplettes Git-Repo
WEBROOT="/var/www/fotobox"            # Nur der website/-Inhalt
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
  jq \
  xserver-xorg-input-evdev \
  xserver-xorg-input-libinput \
  xinput \
  libinput-tools \
  usbutils \
  rsync

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
# cups.socket  = Socket-Aktivierung (Ubuntu-Standard)
# cups-browsed = Drucker-Bekanntmachung im Netz
systemctl enable cups.socket
systemctl enable cups
systemctl enable cups-browsed 2>/dev/null || true
systemctl restart cups.socket
systemctl restart cups
systemctl restart cups-browsed 2>/dev/null || true
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

    # Python-Quellcode nie ausliefern
    location ~ \.py$ {
        deny all;
        return 404;
    }

    # Settings-API → Python-Backend
    location /api/ {
        proxy_pass         http://127.0.0.1:3000;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_read_timeout 10s;
        proxy_connect_timeout 5s;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Statische Assets cachen
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
        expires 7d;
        add_header Cache-Control "public, immutable";
    }

    # Video: längeres Caching, kein Range-Request-Problem
    location ~* \.mp4$ {
        expires 1d;
        add_header Cache-Control "public";
        mp4;
        mp4_buffer_size     1m;
        mp4_max_buffer_size 5m;
    }

    # Kein Cache für HTML und JSON
    location ~* \.(html|json)$ {
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

if [[ -d "$REPO_DIR/.git" ]]; then
  log "Repository existiert bereits, führe git pull aus..."
  git -C "$REPO_DIR" pull --ff-only
else
  rm -rf "$REPO_DIR"
  git clone "$GITHUB_REPO" "$REPO_DIR" || error "GitHub-Repo konnte nicht geklont werden."
fi

# Nur den website/-Unterordner in den Webroot synchronisieren
mkdir -p "$WEBROOT"
rsync -a --delete "$REPO_DIR/website/" "$WEBROOT/"

chown -R www-data:www-data "$WEBROOT"

# =============================================================================
# 7a. FOTOBOX SETTINGS API
# =============================================================================
log "Konfiguriere Fotobox-Settings-API..."

mkdir -p /opt/fotobox

# Python-API aus Repo kopieren
if [[ -f "$REPO_DIR/website/api/server.py" ]]; then
  cp "$REPO_DIR/website/api/server.py" /opt/fotobox/api.py
  chmod 755 /opt/fotobox/api.py
  log "  API-Server nach /opt/fotobox/api.py kopiert."
else
  error "website/api/server.py nicht im geklonten Repo gefunden ($REPO_DIR)."
fi

# Standard-Settings anlegen (falls nicht vorhanden)
if [[ ! -f "$WEBROOT/settings.json" ]]; then
  cat > "$WEBROOT/settings.json" << 'JSON'
{
  "video_duration": 45,
  "gallery_duration": 45,
  "gallery_url": "https://fotoshare.co/e/MT9Ze_2AcJL-7hC1H4kJL"
}
JSON
fi
chown www-data:www-data "$WEBROOT/settings.json"

# Systemd-Service für API
cat > /etc/systemd/system/fotobox-api.service << 'SVC'
[Unit]
Description=Fotobox Settings API
After=network.target

[Service]
Type=simple
User=www-data
ExecStart=/usr/bin/python3 /opt/fotobox/api.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable fotobox-api
systemctl restart fotobox-api
log "  Settings-API gestartet auf Port 3000."

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
ExecStart=/usr/bin/git -C /opt/fotobox-repo pull --ff-only
ExecStartPost=/usr/bin/rsync -a --delete /opt/fotobox-repo/website/ /var/www/fotobox/
ExecStartPost=/bin/chown -R www-data:www-data /var/www/fotobox
ExecStartPost=/bin/cp /opt/fotobox-repo/website/api/server.py /opt/fotobox/api.py
ExecStartPost=/bin/systemctl restart fotobox-api
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
# 8b. BETRONICS TOUCHSCREEN – TREIBER & KALIBRIERUNG
# =============================================================================
log "Konfiguriere Betronics Touchscreen..."

# Betronics Monitore nutzen einen USB-HID-Touchcontroller (meist eGalax oder ILITEK).
# Unter Ubuntu funktioniert das über den generischen evdev/libinput-Stack.

# udev-Regel: Touch-Gerät automatisch als Eingabegerät erkennen
cat > /etc/udev/rules.d/99-betronics-touch.rules << 'UDEV'
# Betronics Touchscreen (USB HID)
SUBSYSTEM=="input", ATTRS{idVendor}=="0eef", ATTRS{idProduct}=="0001", ENV{ID_INPUT_TOUCHSCREEN}="1"
SUBSYSTEM=="input", ATTRS{idVendor}=="222a", ENV{ID_INPUT_TOUCHSCREEN}="1"
SUBSYSTEM=="input", ATTRS{idVendor}=="04d8", ENV{ID_INPUT_TOUCHSCREEN}="1"
UDEV

udevadm control --reload-rules
udevadm trigger

# libinput-Konfiguration: Touch als direkte Eingabe (nicht als Maus)
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/99-betronics-touch.conf << 'XORG'
Section "InputClass"
    Identifier   "Betronics Touchscreen"
    MatchIsTouchscreen "on"
    Driver       "libinput"
    Option       "CalibrationMatrix" "1 0 0 0 1 0 0 0 1"
    Option       "TransformationMatrix" "1 0 0 0 1 0 0 0 1"
EndSection
XORG

log "  Touchscreen-Konfiguration gesetzt."
log "  Touch-Gerät prüfen: xinput list"

# =============================================================================
# 8c. BILDSCHIRMSCHONER & ENERGIESPARMODUS DEAKTIVIEREN
# =============================================================================
log "Deaktiviere Bildschirmschoner und Display-Standby..."

# GNOME: Bildschirmschoner + automatische Sperre komplett abschalten
GNOME_SETTINGS_SCRIPT="/usr/local/bin/fotobox-display-settings.sh"
cat > "$GNOME_SETTINGS_SCRIPT" << GSETTINGS
#!/bin/bash
export DISPLAY=:0
export DBUS_SESSION_BUS_ADDRESS=\$(cat /tmp/fotobox_dbus_addr 2>/dev/null || echo "")

# GNOME: Bildschirmschoner deaktivieren
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
gsettings set org.gnome.desktop.session idle-delay 0

# GNOME Power: Kein Ausschalten bei Inaktivität
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power power-button-action 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false

# X11: DPMS und Blank ausschalten
xset s off
xset s noblank
xset -dpms
GSETTINGS

chmod +x "$GNOME_SETTINGS_SCRIPT"

# Autostart-Eintrag damit es nach jedem Login gilt
AUTOSTART_DIR_DISPLAY="/home/${KIOSK_USER}/.config/autostart"
mkdir -p "$AUTOSTART_DIR_DISPLAY"
cat > "$AUTOSTART_DIR_DISPLAY/fotobox-display.desktop" << DDESK
[Desktop Entry]
Type=Application
Name=Fotobox Display-Einstellungen
Exec=/usr/local/bin/fotobox-display-settings.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
DDESK

chown -R "${KIOSK_USER}:${KIOSK_USER}" "$AUTOSTART_DIR_DISPLAY"

# systemd logind: kein Suspend/Hibernate
cat > /etc/systemd/sleep.conf.d/fotobox.conf << 'SLEEP'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
SLEEP

# logind: Lid-Taste und Power-Taste ignorieren
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/fotobox.conf << 'LOGIND'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
IdleAction=ignore
LOGIND

systemctl daemon-reload
log "  Bildschirmschoner und Standby deaktiviert."

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

# DBUS-Adresse speichern (für gsettings aus anderen Scripts)
dbus-send --session --dest=org.freedesktop.DBus \
  --type=method_call / org.freedesktop.DBus.Peer.Ping 2>/dev/null && \
  echo "\$DBUS_SESSION_BUS_ADDRESS" > /tmp/fotobox_dbus_addr 2>/dev/null || true

# Display-Standby und Bildschirmschoner deaktivieren
xset s off
xset s noblank
xset -dpms
/usr/local/bin/fotobox-display-settings.sh &

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

# nginx Watchdog + Abhängigkeit von fotobox-api
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/restart.conf << 'CONF'
[Unit]
After=fotobox-api.service
Wants=fotobox-api.service

[Service]
Restart=always
RestartSec=5
CONF

# CUPS Watchdog (cups.socket + cups.service)
mkdir -p /etc/systemd/system/cups.service.d
cat > /etc/systemd/system/cups.service.d/restart.conf << 'CONF'
[Service]
Restart=always
RestartSec=5
CONF

mkdir -p /etc/systemd/system/cups.socket.d
cat > /etc/systemd/system/cups.socket.d/restart.conf << 'CONF'
[Unit]
After=network.target

[Socket]
SocketMode=0666
CONF

mkdir -p /etc/systemd/system/cups-browsed.service.d
cat > /etc/systemd/system/cups-browsed.service.d/restart.conf << 'CONF'
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

# Fotobox-API Watchdog
mkdir -p /etc/systemd/system/fotobox-api.service.d
cat > /etc/systemd/system/fotobox-api.service.d/restart.conf << 'CONF'
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
log " Services (alle auf Restart=always + Autostart):"
log "   cups.socket      → CUPS Socket-Aktivierung"
log "   cups             → Druckdienst"
log "   cups-browsed     → AirPrint-Bekanntmachung"
log "   avahi-daemon     → Bonjour/mDNS"
log "   fotobox-api      → Settings-API (Port 3000)"
log "   nginx            → Webserver (startet nach API)"
log "   fotobox-update   → Auto-Update von GitHub (stündlich)"
log "   fotobox-kiosk    → Chromium Vollbild"
log ""
log " Remote-Einstellungen (Handy im selben WLAN):"
log "   http://[IP-der-Fotobox]/settings"
log "============================================================"
