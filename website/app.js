'use strict';

// ============================================================
// Fotobox Kiosk – Video <-> Galerie Wechsel
// Einstellungen werden von /api/settings geladen
// ============================================================

const DEFAULT = {
  video_duration:   45,
  gallery_duration: 45,
  gallery_url:      'https://fotoshare.co/e/MT9Ze_2AcJL-7hC1H4kJL'
};

let settings     = { ...DEFAULT };
let switchTimer  = null;
let currentMode  = 'video';
let modeStart    = Date.now();

const layerVideo    = document.getElementById('layer-video');
const layerGallery  = document.getElementById('layer-gallery');
const galleryFrame  = document.getElementById('gallery-frame');
const bgVideo       = document.getElementById('bg-video');
const videoFallback = document.getElementById('video-fallback');

// --- Video: Fallback wenn Datei fehlt ---
bgVideo.addEventListener('error', () => {
  bgVideo.style.display = 'none';
  videoFallback.classList.add('visible');
});

bgVideo.addEventListener('canplay', () => {
  videoFallback.classList.remove('visible');
  bgVideo.style.display = 'block';
});

// --- Settings API ---
async function fetchSettings() {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 3000);
    const res = await fetch('/api/settings', { signal: ctrl.signal });
    clearTimeout(t);
    if (res.ok) {
      const data = await res.json();
      settings = { ...DEFAULT, ...data };
    }
  } catch { /* Fallback auf Default */ }
}

async function reportStatus() {
  const elapsed  = Math.floor((Date.now() - modeStart) / 1000);
  const duration = currentMode === 'video'
    ? settings.video_duration
    : settings.gallery_duration;
  const remaining = Math.max(0, duration - elapsed);

  try {
    await fetch('/api/status', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ mode: currentMode, next_switch_in: remaining })
    });
  } catch { /* ignore */ }
}

// --- Wechsel: Video anzeigen ---
function showVideo() {
  if (switchTimer) clearTimeout(switchTimer);
  currentMode = 'video';
  modeStart   = Date.now();

  layerGallery.classList.remove('fade-in');
  layerVideo.classList.remove('fade-out');

  bgVideo.play().catch(() => {});

  // Iframe nach Fade entladen
  setTimeout(() => { galleryFrame.src = 'about:blank'; }, 1000);

  reportStatus();
  switchTimer = setTimeout(showGallery, settings.video_duration * 1000);
}

// --- Wechsel: Galerie anzeigen ---
function showGallery() {
  if (switchTimer) clearTimeout(switchTimer);
  currentMode = 'gallery';
  modeStart   = Date.now();

  // Galerie vorladen, dann einblenden
  galleryFrame.src = settings.gallery_url;

  layerVideo.classList.add('fade-out');
  layerGallery.classList.add('fade-in');

  reportStatus();
  switchTimer = setTimeout(showVideo, settings.gallery_duration * 1000);
}

// --- Statusmeldung alle 10 Sek. ---
setInterval(reportStatus, 10000);

// --- Settings alle 30 Sek. pollen ---
setInterval(async () => {
  const snap = JSON.stringify(settings);
  await fetchSettings();
  // Bei Änderung: Timer neu starten
  if (JSON.stringify(settings) !== snap) {
    if (currentMode === 'video') showVideo();
    else showGallery();
  }
}, 30000);

// --- Init ---
async function init() {
  await fetchSettings();
  showVideo();

  // Vollbild beim ersten Touch
  document.addEventListener('click', () => {
    document.documentElement.requestFullscreen().catch(() => {});
  }, { once: true });
}

init();
