// Сгенерировано из bridge/SlouBridge.js (embed_bridge.py) — правь исходник, не этот файл.
import Foundation

/// Скрипт, который приложение встраивает в страницу раньше её собственного кода
enum BridgeScript {
    static let source = #"""
/* СЛОУ · мост приложения для iPhone. Выполняется раньше кода страницы.
   Сервер и сайт не меняются: приложение само перехватывает битву за корону и ведёт её нативно,
   прячет плашку над плеером, даёт Taptic Engine вместо вибрации и сообщает о комнате и голосе. */
(() => {
  'use strict';
  const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.slou;
  if (!h || window.__slouNative) return;
  const post = m => { try { h.postMessage(m); } catch (e) {} };
  window.slouApp = {platform: 'ios', version: '3.1', native: true};
  const withRoot = fn => {
    if (document.documentElement) return fn(document.documentElement);
    new MutationObserver((_, o) => { if (document.documentElement) { o.disconnect(); fn(document.documentElement); } }).observe(document, {childList: true});
  };
  withRoot(root => {
    root.classList.add('is-app', 'is-native');
    // плашка с качеством и «во весь экран» над плеером не нужна: экран разворачивается поворотом
    const css = document.createElement('style');
    css.textContent = '#playerTools{display:none!important}';
    root.appendChild(css);
  });

  // ---- Taptic Engine вместо вибрации
  const kindOf = p => {
    if (Array.isArray(p)) return p.length > 2 ? 'heavy' : 'medium';
    const v = Number(p) || 10;
    return v >= 40 ? 'heavy' : v >= 15 ? 'medium' : 'light';
  };
  try { Object.defineProperty(navigator, 'vibrate', {configurable: true, value: p => { post({t: 'haptic', s: kindOf(p)}); return true; }}); } catch (e) {}
  if (!window.slouHaptic) window.slouHaptic = (kind = 'light') => post({t: 'haptic', s: String(kind)});

  // ---- системное «Поделиться»
  try {
    Object.defineProperty(navigator, 'share', {configurable: true, value: d => { d = d || {}; post({t: 'share', url: d.url || '', text: d.text || d.title || ''}); return Promise.resolve(); }});
    Object.defineProperty(navigator, 'canShare', {configurable: true, value: () => true});
  } catch (e) {}

  // ---- портреты: avatarSvg — глобальная функция страницы, достаём из неё адрес картинки
  const faceUrl = i => {
    try {
      // eslint-disable-next-line no-undef
      const f = typeof avatarSvg === 'function' ? avatarSvg : window.avatarSvg;
      const svg = f ? String(f(Number(i) || 0, false)) : '';
      const m = /href="([^"]+)"/.exec(svg);
      return m ? new URL(m[1], location.href).href : '';
    } catch (e) { return ''; }
  };

  // ---- битва за корону: страница отдаёт свой модуль, приложение подменяет его своим
  let web = null, busy = false;
  const handled = new Set();
  const crown = {
    offer() { return !busy && !!(web && web.offer && web.offer()); },
    challenge() {
      if (!crown.offer()) return;
      const r = window.cinemaRoom || {};
      post({t: 'crown', a: r.peerOnline ? 'challenge' : 'offline'});
    },
    receive(ev, data, s) {
      if (!ev || handled.has(ev.id)) return;
      handled.add(ev.id);
      const d = ev.data || {}, now = Number(data && data.now) || Date.now(), at = Number(ev.at) || 0;
      const du = data && data.duel;
      post({t: 'crown', a: 'event', id: Number(ev.id) || 0, act: String(d.act || ''), accept: !!d.accept, duel: Number(d.duel) || 0,
        at, now, age: now - at, seat: String(ev.seat || ''), mine: s && s.scope === 'guest' ? 'friend' : 'host', scope: (s && s.scope) || '',
        swap: !!d.swap, crown: Number(d.crown) || 0, poop: Number(d.poop) || 0, forfeit: !!d.forfeit,
        actorName: String((ev.actor && ev.actor.name) || ''), actorFace: faceUrl(ev.actor && ev.actor.avatar),
        state: du && du.id === ev.id ? String(du.state || '') : ''});
    },
    sync(data, s) {
      let swapped = false;
      // свой модуль страницы по-прежнему пересаживает места и рисует 💩 — без своей арены
      try { swapped = !!(web && web.sync && web.sync(Object.assign({}, data, {duel: null}), s)); } catch (e) {}
      const du = data && data.duel;
      post({t: 'crown', a: 'sync', now: Number(data && data.now) || Date.now(), poop: !!(data && data.poop),
        duel: du ? {id: Number(du.id) || 0, state: String(du.state || ''), at: Number(du.at) || 0} : null});
      return swapped;
    },
    peek() { return null; },
    get games() { return (web && web.games) || []; }
  };
  try { Object.defineProperty(window, 'slouCrown', {configurable: true, enumerable: true, get: () => crown, set: v => { web = v; }}); } catch (e) {}

  // ---- то, что приложение спрашивает у страницы
  window.__slouNative = {
    busy(v) { busy = !!v; return busy; },
    info() {
      const s = window.roomPortal && window.roomPortal.getSession && window.roomPortal.getSession();
      if (!s || !s.code) return JSON.stringify(null);
      const r = window.cinemaRoom || {};
      return JSON.stringify({code: s.code, scope: s.scope, ownerKey: s.ownerKey || '', guestKey: s.guestKey || '',
        name: r.name || '', peerName: r.peerName || '', meFace: faceUrl(r.avatar), peerFace: faceUrl(r.peerAvatar),
        peerOnline: !!r.peerOnline, origin: location.origin});
    },
    async send(kind, data) {
      try {
        if (!window.roomWire || !window.roomWire.send) throw Error('Нет соединения с комнатой.');
        const res = await window.roomWire.send(kind, data);
        return JSON.stringify({ok: true, res: res == null ? null : res});
      } catch (e) {
        return JSON.stringify({ok: false, error: String((e && e.message) || e || 'Ошибка')});
      }
    },
    closeDialogs() {
      for (const d of document.querySelectorAll('dialog[open]')) { try { d.close(); } catch (e) {} }
      return true;
    },
    // телефон повернули: фильм во весь экран и обратно
    landscape(on) {
      const r = window.cinemaRoom || {};
      if (!r.inRoom) return 'home';
      const btn = document.getElementById('stageExpand');
      if (!btn || btn.disabled) return 'none';
      const screen = document.getElementById('screen');
      const open = btn.getAttribute('aria-pressed') === 'true' || !!(screen && screen.classList.contains('stage-immersive')) || !!document.fullscreenElement;
      if (!!on !== open) btn.click();
      return 'ok';
    }
  };

  const ready = fn => document.readyState === 'loading' ? document.addEventListener('DOMContentLoaded', fn, {once: true}) : fn();
  ready(() => {
    // комната: экран не гаснет, пока ты в комнате
    let roomKey = null;
    const report = () => {
      const s = window.roomPortal && window.roomPortal.getSession && window.roomPortal.getSession();
      const key = s && s.inRoom ? s.code + ':' + s.scope : '';
      if (key === roomKey) return;
      roomKey = key;
      post(key ? {t: 'room', code: s.code, owner: s.scope === 'owner'} : {t: 'home'});
    };
    window.addEventListener('room-view', report);
    setInterval(report, 2000);
    report();

    // голос: микрофон включён — звук в режиме разговора, выключен — в режиме кино
    let voice = null;
    window.addEventListener('room-mic-state', e => {
      const mode = e.detail && e.detail.mode;
      const on = !!mode && mode !== 'idle' && mode !== 'requesting';
      if (on !== voice) { voice = on; post({t: 'voice', on}); }
    });

    // фильм на весь экран — приложение прячет строку состояния
    let wide = false;
    new MutationObserver(() => {
      const f = !!document.querySelector('#screen.stage-immersive') || !!document.fullscreenElement;
      if (f !== wide) { wide = f; post({t: 'immersive', on: f}); }
    }).observe(document.body, {subtree: true, attributes: true, attributeFilter: ['class']});

    // «Сохранить» у фото и видео из чата — сразу в Фото
    document.addEventListener('click', e => {
      const a = e.target && e.target.closest && e.target.closest('a.md-save');
      if (!a) return;
      e.preventDefault();
      e.stopPropagation();
      post({t: 'save', url: new URL(a.getAttribute('href'), location.href).href});
    }, true);
  });

  // после звонка, Siri или смены наушников приложение будит звук и видео
  if (!window.slouResume) {
    window.slouResume = () => {
      window.dispatchEvent(new Event('slou-resume'));
      try { window.slouSfx && window.slouSfx.unlock && window.slouSfx.unlock(); } catch (e) {}
      for (const m of document.querySelectorAll('video,audio')) if (!m.paused) m.play().catch(() => {});
    };
  }
})();
"""#
}
