// Wires the page: the spectrum field, the sound controls, and the download buttons that read the
// release lists on GitHub. The only requests this script makes go to api.github.com.

import { SpectrumScene } from './spectrum.js';
import { Background, freqOfBin } from './groove.js';

const $ = s => document.querySelector(s);
const $$ = s => Array.from(document.querySelectorAll(s));

// --- The field ------------------------------------------------------------------------------

let scene = null, background = null;
const canvas = $('#field');
try {
  scene = new SpectrumScene(canvas);
  background = new Background(scene);
  document.documentElement.classList.add('has-field');
  window.joseonField = { scene, background };   // for a look in the console; nothing reads it
} catch (e) {
  canvas.remove();
  $('#sound').hidden = true;
}

if (scene) {
  const readout = $('#readout');
  let readoutUntil = 0;
  const noteName = f => {
    const n = Math.round(12 * Math.log2(f / 440) + 69);
    const names = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];
    return names[((n % 12) + 12) % 12] + (Math.floor(n / 12) - 1);
  };
  const fmtHz = f => f >= 1000 ? (f / 1000).toFixed(f >= 10000 ? 1 : 2) + ' kHz' : Math.round(f) + ' Hz';
  window.addEventListener('pointermove', e => {
    // The readout only over the field itself, not over text or buttons.
    const overField = e.target.closest && e.target.closest('.hero') && !e.target.closest('#sound, .btn, p, h1, h2, .eyebrow, .meta');
    readoutUntil = overField ? performance.now() + 1400 : 0;
    readout.style.transform = `translate(${e.clientX + 16}px, ${e.clientY + 18}px)`;
  }, { passive: true });

  // A hidden tab gets no animation frames; frame() skips ahead when they come back.
  // Nothing is drawn while the hero is scrolled out of view; frame() skips ahead when it comes back.
  let heroVisible = true;
  if (window.IntersectionObserver) new IntersectionObserver(([en]) => { heroVisible = en.isIntersecting; }).observe($('.hero'));
  function loop(now) {
    if (heroVisible) {
      background.frame(now);
      scene.draw(now / 1000);
    }
    const bin = scene.hover;
    if (bin >= 0 && now < readoutUntil) {
      const f = freqOfBin(bin);
      readout.textContent = `${fmtHz(f)} · ${noteName(f)}`;
      readout.classList.add('on');
    } else {
      readout.classList.remove('on');
    }
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
  background.prepare();

  // --- Sound controls ---
  const btnListen = $('#btn-listen'), btnMic = $('#btn-mic'), btnFile = $('#btn-file'), fileInput = $('#file-input');
  const status = $('#sound-status');
  const say = text => { status.textContent = text; };
  background.onchange = () => {
    const m = background.mode;
    btnListen.classList.toggle('active', m === 'groove');
    btnMic.classList.toggle('active', m === 'mic');
    btnFile.classList.toggle('active', m === 'file');
    btnListen.querySelector('span').textContent = m === 'groove' ? 'Mute' : 'Hear the groove';
    btnListen.disabled = !background.ready && !background.error;
    if (background.error) { btnListen.disabled = true; say('This browser could not render the groove.'); return; }
    if (m === 'silent') say(background.ready ? 'Moving to a bossa nova loop made in your browser. Sound is off.' : 'Rendering the loop…');
    if (m === 'groove') say('Playing the loop. Everything you see is its spectrum.');
    if (m === 'mic') say('Listening to your microphone. The sound stays in this browser tab.');
    if (m === 'file') say(`Playing ${background.live?.name || 'your file'} locally. Nothing is uploaded.`);
  };
  background.onchange();
  btnListen.addEventListener('click', () => background.mode === 'groove' ? background.silence() : background.listen());
  btnMic.addEventListener('click', async () => {
    if (background.mode === 'mic') { background.silence(); return; }
    try { await background.mic(); } catch (e) { say('No microphone: ' + (e.message || e.name)); }
  });
  btnFile.addEventListener('click', () => background.mode === 'file' ? background.silence() : fileInput.click());
  fileInput.addEventListener('change', async () => {
    const f = fileInput.files && fileInput.files[0];
    if (!f) return;
    try { await background.file(f); } catch (e) { say('That file did not decode: ' + (e.message || e.name)); }
    fileInput.value = '';
  });
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) btnMic.hidden = true;
  if (!window.isSecureContext) btnMic.hidden = true;
}

// --- Downloads -------------------------------------------------------------------------------

const REPOS = {
  mac: { repo: 'jasas1/Joseon', suffixes: ['-macos.dmg', '-macos.zip'], label: 'macOS' },
  win: { repo: 'jasas1/JoseonPC', suffixes: ['-windows-x64.zip'], label: 'Windows' },
};

const fmtSize = n => n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.round(n / 1024) + ' KB';
const fmtDate = iso => new Date(iso).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });

async function releases(repo) {
  const key = 'rel:' + repo;
  try {
    const cached = JSON.parse(sessionStorage.getItem(key) || 'null');
    if (cached && Date.now() - cached.at < 10 * 60 * 1000) return cached.list;
  } catch (_) { /* storage may be off */ }
  const r = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=10`, {
    headers: { Accept: 'application/vnd.github+json' },
  });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  const list = await r.json();
  try { sessionStorage.setItem(key, JSON.stringify({ at: Date.now(), list })); } catch (_) { /* fine */ }
  return list;
}

function newest(list, suffixes) {
  for (const rel of list) {
    if (rel.draft) continue;
    for (const suffix of suffixes) {
      const asset = (rel.assets || []).find(a => a.name.endsWith(suffix));
      if (asset) return { rel, asset };
    }
  }
  return null;
}

async function fillDownload(kind) {
  const { repo, suffixes } = REPOS[kind];
  const cards = $$(`[data-download="${kind}"]`);
  let found = null, failed = false;
  try { found = newest(await releases(repo), suffixes); } catch (_) { failed = true; }
  for (const card of cards) {
    const link = card.querySelector('a.btn');
    const meta = card.querySelector('.meta');
    if (found) {
      const { rel, asset } = found;
      link.href = asset.browser_download_url;
      link.querySelector('.btn-sub').textContent = `${asset.name} · ${fmtSize(asset.size)}`;
      meta.innerHTML = `${rel.prerelease ? '<span class="tag">test build</span> ' : ''}${rel.tag_name} · ${fmtDate(rel.published_at)} · <a href="${rel.html_url}">notes</a>`;
      card.classList.add('ready');
    } else {
      link.href = `https://github.com/${repo}/releases`;
      link.querySelector('.btn-sub').textContent = failed ? 'Open the releases page' : 'No build published yet';
      meta.textContent = failed ? 'The release list could not be read just now.' : '';
      card.classList.add(failed ? 'failed' : 'pending');
    }
  }
}
fillDownload('mac');
fillDownload('win');

// Which platform is this visitor on? Only to put that button first.
const ua = navigator.userAgent;
if (/Windows/i.test(ua)) document.documentElement.classList.add('on-win');
else if (/Macintosh|Mac OS/i.test(ua)) document.documentElement.classList.add('on-mac');

// The year in the footer, and the commit facts stay as written.
$('#year').textContent = new Date().getFullYear();
