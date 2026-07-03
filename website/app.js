// ============================================================
// Fotobox App – Einfache Kiosk-Logik
// ============================================================

const screens = {
  start:     document.getElementById('screen-start'),
  countdown: document.getElementById('screen-countdown'),
  photo:     document.getElementById('screen-photo'),
  done:      document.getElementById('screen-done'),
};

const countdownEl = document.getElementById('countdown');
const flashEl     = document.getElementById('flash');

function showScreen(name) {
  Object.values(screens).forEach(s => s.classList.add('hidden'));
  screens[name].classList.remove('hidden');
}

function startSession() {
  showScreen('countdown');
  runCountdown(3);
}

function runCountdown(n) {
  if (n <= 0) {
    takePhoto();
    return;
  }
  countdownEl.textContent = n;
  // Neu-Animation auslösen
  countdownEl.style.animation = 'none';
  void countdownEl.offsetWidth; // Reflow
  countdownEl.style.animation = '';

  setTimeout(() => runCountdown(n - 1), 1000);
}

function takePhoto() {
  showScreen('photo');

  // Blitz-Effekt
  flashEl.classList.add('active');
  setTimeout(() => flashEl.classList.remove('active'), 150);

  // Nach 2 Sekunden: fertig
  setTimeout(() => showScreen('done'), 2000);
}

function reset() {
  showScreen('start');
}

// Touchscreen: Vollbild versuchen
document.addEventListener('click', () => {
  if (!document.fullscreenElement) {
    document.documentElement.requestFullscreen().catch(() => {});
  }
}, { once: true });
