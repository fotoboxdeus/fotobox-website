#!/bin/bash
# =============================================================================
# GitHub Repository erstellen: fotoboxdeus/fotobox-website
# Benötigt: gh CLI (GitHub CLI) oder curl + Personal Access Token
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

GITHUB_USER="fotoboxdeus"
REPO_NAME="fotobox-website"
REPO_DESC="Fotobox Kiosk Website"
WEBSITE_DIR="$(dirname "$0")/website"

echo ""
echo "============================================================"
echo " GitHub Repository einrichten"
echo " → $GITHUB_USER/$REPO_NAME"
echo "============================================================"
echo ""

# --- Methode 1: GitHub CLI (empfohlen) ---
if command -v gh &>/dev/null; then
  log "GitHub CLI gefunden."

  # Einloggen falls noch nicht
  if ! gh auth status &>/dev/null; then
    log "Bitte bei GitHub anmelden..."
    gh auth login
  fi

  # Repo erstellen (falls nicht vorhanden)
  if gh repo view "$GITHUB_USER/$REPO_NAME" &>/dev/null 2>&1; then
    warn "Repository existiert bereits: $GITHUB_USER/$REPO_NAME"
  else
    log "Erstelle Repository $GITHUB_USER/$REPO_NAME..."
    gh repo create "$GITHUB_USER/$REPO_NAME" \
      --public \
      --description "$REPO_DESC" \
      --clone=false
    log "Repository erstellt."
  fi

  # Website-Dateien committen
  if [[ -d "$WEBSITE_DIR" ]]; then
    TMPDIR_REPO=$(mktemp -d)
    gh repo clone "$GITHUB_USER/$REPO_NAME" "$TMPDIR_REPO" 2>/dev/null || \
      git clone "https://github.com/$GITHUB_USER/$REPO_NAME.git" "$TMPDIR_REPO"

    cp -r "$WEBSITE_DIR/." "$TMPDIR_REPO/"

    cd "$TMPDIR_REPO"
    git add -A
    git diff --cached --quiet || {
      git commit -m "Initiale Fotobox-Website"
      git push origin main
      log "Website auf GitHub hochgeladen."
    }
    cd - > /dev/null
    rm -rf "$TMPDIR_REPO"
  fi

# --- Methode 2: curl + Personal Access Token ---
else
  warn "GitHub CLI nicht installiert. Nutze API mit Personal Access Token."
  echo ""
  echo "  GitHub CLI installieren (empfohlen):"
  echo "    sudo apt install gh"
  echo "  Danach: gh auth login"
  echo ""
  echo "  Alternativ: GitHub Personal Access Token eingeben"
  echo "  (Token erstellen unter: https://github.com/settings/tokens)"
  echo ""
  read -rsp "GitHub Personal Access Token: " GH_TOKEN
  echo ""

  if [[ -z "$GH_TOKEN" ]]; then
    error "Kein Token eingegeben. Abgebrochen."
  fi

  # Repo erstellen
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/user/repos \
    -d "{\"name\":\"$REPO_NAME\",\"description\":\"$REPO_DESC\",\"private\":false,\"auto_init\":true}")

  if [[ "$RESPONSE" == "201" ]]; then
    log "Repository erfolgreich erstellt."
  elif [[ "$RESPONSE" == "422" ]]; then
    warn "Repository existiert bereits (HTTP 422)."
  else
    error "Fehler beim Erstellen des Repos (HTTP $RESPONSE)."
  fi

  # Website hochladen via git
  if [[ -d "$WEBSITE_DIR" ]]; then
    TMPDIR_REPO=$(mktemp -d)
    git clone "https://$GH_TOKEN@github.com/$GITHUB_USER/$REPO_NAME.git" "$TMPDIR_REPO" || \
      error "Repo konnte nicht geklont werden."

    cp -r "$WEBSITE_DIR/." "$TMPDIR_REPO/"
    cd "$TMPDIR_REPO"
    git add -A
    git diff --cached --quiet || {
      git commit -m "Initiale Fotobox-Website"
      git push
      log "Website auf GitHub hochgeladen."
    }
    cd - > /dev/null
    rm -rf "$TMPDIR_REPO"
    unset GH_TOKEN
  fi
fi

log ""
log "Fertig! Repository: https://github.com/$GITHUB_USER/$REPO_NAME"
