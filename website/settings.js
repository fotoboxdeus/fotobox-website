'use strict';

// ============================================================
// Fotobox Settings – Remote-Steuerung vom Handy
// ============================================================

const inpVideo   = document.getElementById('inp-video');
const inpGallery = document.getElementById('inp-gallery');
const inpUrl     = document.getElementById('inp-url');
const badgeVideo = document.getElementById('badge-video');
const badgeGallery = document.getElementById('badge-gallery');

const statusDot  = document.getElementById('status-dot');
const statusMode = document.getElementById('status-mode');
const statusNext = document.getElementById('status-next');

const deviceUrl  = document.getElementById('device-url');
const toast      = document.getElementById('toast');

let countdownInterval = null;
let lastNextSwitch    = 0;

// ─── Slider Live-Update ─────────────────────────────────────
inpVideo.addEventListener('input', () => {
  badgeVideo.textContent = formatSec(inpVideo.value);
});

inpGallery.addEventListener('input', () => {
  badgeGallery.textContent = formatSec(inpGallery.value);
});

function formatSec(s) {
  const n = parseInt(s, 10);
  return n >= 60 ? `${(n / 60).toFixed(n % 60 === 0 ? 0 : 1)} Min.` : `${n} Sek.`;
}

// ─── Settings laden ─────────────────────────────────────────
async function loadSettings() {
  try {
    const res = await fetch('/api/settings');
    if (!res.ok) return;
    const d = await res.json();

    inpVideo.value   = d.video_duration   ?? 45;
    inpGallery.value = d.gallery_duration ?? 45;
    inpUrl.value     = d.gallery_url      ?? '';

    badgeVideo.textContent   = formatSec(inpVideo.value);
    badgeGallery.textContent = formatSec(inpGallery.value);
  } catch { /* ignore */ }
}

// ─── Status laden ────────────────────────────────────────────
async function loadStatus() {
  try {
    const res = await fetch('/api/status');
    if (!res.ok) throw new Error();
    const d = await res.json();

    const modeLabel = d.mode === 'video'
      ? '🎬 Video läuft'
      : d.mode === 'gallery'
        ? '🖼 Galerie läuft'
        : 'Unbekannt';

    statusMode.textContent = modeLabel;
    statusDot.className = `status-dot ${d.mode}`;

    // Countdown starten
    if (countdownInterval) clearInterval(countdownInterval);
    lastNextSwitch = parseInt(d.next_switch_in, 10) || 0;
    updateCountdown();
    countdownInterval = setInterval(updateCountdown, 1000);

  } catch {
    statusMode.textContent = 'Nicht verbunden';
    statusDot.className = 'status-dot';
    statusNext.textContent = '';
  }
}

function updateCountdown() {
  if (lastNextSwitch <= 0) {
    statusNext.textContent = 'Wechsel gleich…';
    return;
  }
  const m = Math.floor(lastNextSwitch / 60);
  const s = lastNextSwitch % 60;
  statusNext.textContent = `Wechsel in ${m > 0 ? m + 'min ' : ''}${s}s`;
  lastNextSwitch--;
}

// ─── Gerät-IP anzeigen ───────────────────────────────────────
async function loadInfo() {
  let ip = window.location.hostname;
  try {
    const res = await fetch('/api/info');
    if (res.ok) {
      const d = await res.json();
      ip = d.ip;
    }
  } catch {}

  deviceUrl.textContent = `http://${ip}/settings`;

  // CUPS-Button direkt auf Port 631 zeigen
  const cupsBtn  = document.getElementById('btn-cups');
  const cupsHint = document.getElementById('cups-hint');
  const cupsUrl  = `http://${ip}:631`;
  cupsBtn.href   = cupsUrl;
  if (cupsHint) cupsHint.textContent = cupsUrl;
}

// ─── Speichern ───────────────────────────────────────────────
async function saveSettings() {
  const url = inpUrl.value.trim();
  if (url && !url.match(/^https?:\/\//)) {
    showToast('⚠ URL muss mit http:// oder https:// beginnen', true);
    return;
  }

  const payload = {
    video_duration:   parseInt(inpVideo.value, 10),
    gallery_duration: parseInt(inpGallery.value, 10),
    gallery_url:      url
  };

  try {
    const res = await fetch('/api/settings', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(payload)
    });

    if (res.ok) {
      showToast('✓ Gespeichert – übernommen in ≤30 Sek.');
    } else {
      showToast('⚠ Fehler beim Speichern', true);
    }
  } catch {
    showToast('⚠ Keine Verbindung zur Fotobox', true);
  }
}

// ─── Toast ───────────────────────────────────────────────────
function showToast(msg, isError = false) {
  toast.textContent = msg;
  toast.className = `toast${isError ? ' error' : ''} show`;
  setTimeout(() => toast.classList.remove('show'), 3000);
}

// ─── Init ────────────────────────────────────────────────────
loadSettings();
loadStatus();
loadInfo();

// Status alle 5 Sek. aktualisieren
setInterval(loadStatus, 5000);
