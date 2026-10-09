import './style.css';
import * as sdk from 'matrix-js-sdk';
import * as CA from 'matrix-js-sdk/lib/crypto-api/index.js';
import { encryptAttachment, decryptAttachment, encryptKeyExport, decryptKeyExport } from './attachments.js';
import CALLS_CFG from './calls.config.js';

const { ClientEvent, RoomEvent, RoomMemberEvent, MatrixEventEvent } = sdk;

/* ---------- constants & small helpers ---------- */
const $ = s => document.querySelector(s);
const enc = encodeURIComponent;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const LS_SESSION = 'mxtg.session', LS_THEME = 'mxtg.theme', DB_PREFIX = 'mxtg';
const COLORS = ['#e17076','#faa774','#a695e7','#7bc862','#6ec9cb','#65aadd','#ee7aae'];
const REACTIONS = ['👍','❤️','😂','😮','😢','🔥','🙏'];
const TAIL = '<svg class="tail" viewBox="0 0 9 20"><path d="M6 17H0V0c.193 2.84.876 5.767 2.05 8.782.904 2.325 2.446 4.485 4.625 6.48A1 1 0 016 17z"/></svg>';
const I = {
  check:'<svg width="16" height="11" viewBox="0 0 16 11" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M1.5 5.8l3.2 3.2L11.5 1.8"/></svg>',
  double:'<svg width="18" height="11" viewBox="0 0 18 11" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M1.5 5.8l3.2 3.2L11.5 1.8M8 8.6l.4.4 7.2-7.2"/></svg>',
  clock:'<svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="8" cy="8" r="6.2"/><path d="M8 4.6V8l2.2 1.4"/></svg>',
  lock:'<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><path d="M17 9V7A5 5 0 007 7v2a2 2 0 00-2 2v8a2 2 0 002 2h10a2 2 0 002-2v-8a2 2 0 00-2-2zm-8 0V7a3 3 0 016 0v2z"/></svg>',
  doc:'<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8z"/><path d="M14 3v5h5"/></svg>',
  reply:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 8L4 13l6 5"/><path d="M4 13h10a6 6 0 016 6"/></svg>',
  copy:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 00-2-2H6a2 2 0 00-2 2v8a2 2 0 002 2h2"/></svg>',
  edit:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M4 20h4L19 9l-4-4L4 16z"/></svg>',
  trash:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/></svg>',
  retry:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M20 12a8 8 0 11-2.3-5.7M20 4v5h-5"/></svg>',
  user:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0116 0"/></svg>',
  group:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="9" cy="8" r="3.5"/><path d="M2 20a7 7 0 0114 0M16 4.5a3.5 3.5 0 010 7M18 14a6 6 0 014 6"/></svg>',
  join:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M10 14a5 5 0 007 0l3-3a5 5 0 00-7-7l-1 1M14 10a5 5 0 00-7 0l-3 3a5 5 0 007 7l1-1"/></svg>',
  key:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="8" cy="15" r="4"/><path d="M11 12l9-9M17 6l3 3M15 8l2 2"/></svg>',
  moon:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M20 14.5A8 8 0 019.5 4a8 8 0 1010.5 10.5z"/></svg>',
  out:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 4h3a2 2 0 012 2v12a2 2 0 01-2 2h-3M10 16l-4-4 4-4M6 12h10"/></svg>',
  smile:'<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M8.5 14.5a4.5 4.5 0 007 0"/><circle cx="9" cy="9.5" r=".8" fill="currentColor"/><circle cx="15" cy="9.5" r=".8" fill="currentColor"/></svg>',
  mic:'<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M12 15a3.5 3.5 0 003.5-3.5v-6a3.5 3.5 0 00-7 0v6A3.5 3.5 0 0012 15z"/><path d="M18.5 11.5a.9.9 0 10-1.8 0 4.7 4.7 0 01-9.4 0 .9.9 0 10-1.8 0 6.5 6.5 0 005.6 6.4V20H8.8a.9.9 0 100 1.8h6.4a.9.9 0 100-1.8h-2.3v-2.1a6.5 6.5 0 005.6-6.4z"/></svg>',
  send:'<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M3.4 20.4l17.4-7.5a1 1 0 000-1.8L3.4 3.6a.9.9 0 00-1.3 1l1.9 6.4 9 1-9 1-1.9 6.4a.9.9 0 001.3 1z"/></svg>',
  play:'<svg width="22" height="22" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5.5v13a1 1 0 001.5.9l10.4-6.5a1 1 0 000-1.7L9.5 4.6A1 1 0 008 5.5z"/></svg>',
  pause:'<svg width="22" height="22" viewBox="0 0 24 24" fill="currentColor"><rect x="6.5" y="5" width="4" height="14" rx="1.2"/><rect x="13.5" y="5" width="4" height="14" rx="1.2"/></svg>',
  download:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11M7 10l5 5 5-5M5 20h14"/></svg>',
  sticker:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M14 3H6a3 3 0 00-3 3v12a3 3 0 003 3h8l7-7V6a3 3 0 00-3-3z"/><path d="M14 21v-4a3 3 0 013-3h4"/></svg>',
  shield:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M12 3l8 3v6c0 4.5-3.4 8.2-8 9-4.6-.8-8-4.5-8-9V6z"/><path d="M8.5 12l2.5 2.5 4.5-5"/></svg>',
  warn:'<svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2.5L1.5 21h21zM11 9h2v6h-2zm0 8h2v2h-2z"/></svg>',
  dots:'<svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/></svg>',
  forward:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 8l6 5-6 5"/><path d="M20 13H10a6 6 0 00-6 6"/></svg>',
  pin:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 4h6l-1 6 3 3H7l3-3z"/><path d="M12 13v8"/></svg>',
  gear:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 01-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 010-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3H9a1.7 1.7 0 001-1.5V3a2 2 0 014 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8V9a1.7 1.7 0 001.5 1H21a2 2 0 010 4h-.1a1.7 1.7 0 00-1.5 1z"/></svg>',
  phone:'<svg width="26" height="26" viewBox="0 0 24 24" fill="currentColor"><path d="M6.6 10.8a15.1 15.1 0 006.6 6.6l2.2-2.2a1 1 0 011-.25 11.4 11.4 0 003.6.57 1 1 0 011 1V20a1 1 0 01-1 1A17 17 0 013 4a1 1 0 011-1h3.5a1 1 0 011 1c0 1.25.2 2.45.57 3.6a1 1 0 01-.25 1z"/></svg>',
  hang:'<svg width="28" height="28" viewBox="0 0 24 24" fill="currentColor"><path d="M12 9c-1.6 0-3.15.25-4.6.72v3.1a1 1 0 01-.56.9 11.5 11.5 0 00-2.66 1.85 1 1 0 01-1.4 0L.29 13.08a1 1 0 010-1.41A16.9 16.9 0 0112 7c4.54 0 8.66 1.78 11.71 4.67a1 1 0 010 1.41l-2.48 2.48a1 1 0 01-1.4 0 11.3 11.3 0 00-2.67-1.85 1 1 0 01-.56-.9v-3.1A15 15 0 0012 9z"/></svg>',
  cam:'<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="2.5" y="6" width="13" height="12" rx="2"/><path d="M15.5 10.5l6-3.5v10l-6-3.5z"/></svg>',
  camOff:'<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="6" width="13" height="12" rx="2"/><path d="M15.5 10.5l6-3.5v10l-6-3.5zM3 3l18 18"/></svg>',
  micOff:'<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 9v2.5a3 3 0 005.1 2.1M15 9.3V5.5a3 3 0 00-6 0M18.5 11.5a6.5 6.5 0 01-1 3.4M5.5 11.5a6.5 6.5 0 0010 5.4M12 18v3M3 3l18 18"/></svg>',
  back:'<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18l-6-6 6-6"/></svg>',
  chevR:'<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6-6 6"/></svg>',
  chevDown:'<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"/></svg>',
  expand:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7"/></svg>',
  chat:'<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M4 5h16v11H9l-5 4z"/></svg>',
  eye:'<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>',
  eyeOff:'<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M10.6 5.1A10.4 10.4 0 0112 5c6.4 0 10 7 10 7a17 17 0 01-3 3.9M6.6 6.6C3.8 8.4 2 12 2 12s3.6 7 10 7a9.7 9.7 0 005.4-1.6M9.9 9.9a3 3 0 004.2 4.2M3 3l18 18"/></svg>',
  close:'<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>',
};

const S = {
  client:null, hs:'', token:'', userId:'', deviceId:'', initialDone:false, online:true,
  me:{name:'', avatar:''}, dm:{}, current:null, reply:null, editing:null, search:'',
  typingSent:0, uploads:new Map(), ui:new Map(), sentReceipt:new Map(),
  cstate:{ready:false, hasCS:false, verified:false},
  locked:false, find:null, pinIdx:new Map(), recording:false,
};
const mediaReady = new Map(), mediaPending = new Map();

function hash(s){ let h = 0; for (const ch of String(s)) h = (h * 31 + ch.codePointAt(0)) | 0; return Math.abs(h); }
const color = s => COLORS[hash(s) % COLORS.length];
const localpart = uid => String(uid || '').replace(/^[@#!]/, '').split(':')[0];
function initials(name){
  const w = String(name || '?').replace(/^[@#!]/, '').trim().split(/\s+/).filter(Boolean);
  const a = [...(w[0] || '?')][0] || '?', b = w[1] ? [...w[1]][0] : '';
  return (a + b).toUpperCase();
}
function plural(n, f){ const a = Math.abs(n) % 100, b = a % 10; return n + ' ' + (a > 10 && a < 20 ? f[2] : b > 1 && b < 5 ? f[1] : b === 1 ? f[0] : f[2]); }
const fmtTime = ts => new Date(ts).toLocaleTimeString('ru-RU', {hour:'2-digit', minute:'2-digit'});
const dayKey = ts => new Date(ts).toDateString();
function fmtDay(ts){
  const d = new Date(ts), now = new Date(), y = new Date(); y.setDate(now.getDate() - 1);
  if (d.toDateString() === now.toDateString()) return 'Сегодня';
  if (d.toDateString() === y.toDateString()) return 'Вчера';
  return d.toLocaleDateString('ru-RU', {day:'numeric', month:'long', ...(d.getFullYear() !== now.getFullYear() ? {year:'numeric'} : {})});
}
function listTime(ts){
  if (!ts || ts < 0) return '';
  const d = new Date(ts), now = new Date();
  if (d.toDateString() === now.toDateString()) return fmtTime(ts);
  if (now - d < 6 * 864e5) { const w = d.toLocaleDateString('ru-RU', {weekday:'short'}); return w[0].toUpperCase() + w.slice(1); }
  return d.toLocaleDateString('ru-RU', {day:'2-digit', month:'2-digit', year:'2-digit'});
}
function fmtSize(b){ if (!b && b !== 0) return ''; const u = ['Б','КБ','МБ','ГБ']; let i = 0; while (b >= 1024 && i < 3) { b /= 1024; i++; } return (i ? b.toFixed(1) : b) + ' ' + u[i]; }
function linkify(html){ return html.replace(/(https?:\/\/[^\s<]+[^\s<.,;:!?)\]'"])/g, '<a href="$1" target="_blank" rel="noopener noreferrer">$1</a>'); }
const stripReply = body => { const b = String(body || ''); return b.startsWith('> <') ? b.replace(/^(?:>.*(?:\n|$))+\n?/, '') : b; };
function isEmojiOnly(t){ const s = t.trim(); return s.length <= 12 && /^(\p{Extended_Pictographic}|\p{Emoji_Component}|\u200d|\ufe0f|\s)+$/u.test(s) && /\p{Extended_Pictographic}/u.test(s); }
let toastT;
function toast(msg, sticky){ const t = $('#toast'); t.textContent = msg; t.hidden = false; clearTimeout(toastT); if (!sticky) toastT = setTimeout(() => t.hidden = true, 4000); }
const crypto_ = () => S.client?.getCrypto?.();
const uiOf = id => { let u = S.ui.get(id); if (!u) S.ui.set(id, u = {loadingOlder:false, reachedStart:false, failAt:0}); return u; };

/* ---------- media ---------- */
function mxcParts(mxc){ const m = /^mxc:\/\/([^/]+)\/([^?#/]+)/.exec(mxc || ''); return m ? [m[1], m[2]] : null; }
async function rawDownload(mxc, thumb){
  const parts = mxcParts(mxc);
  if (!parts) throw new Error('Некорректная ссылка на файл');
  const q = thumb ? `thumbnail/${enc(parts[0])}/${enc(parts[1])}?width=${thumb}&height=${thumb}&method=scale` : `download/${enc(parts[0])}/${enc(parts[1])}`;
  for (const base of ['/_matrix/client/v1/media/', '/_matrix/media/v3/']) {
    try {
      const r = await fetch(S.hs + base + q, {headers:{Authorization:'Bearer ' + S.token}});
      if (r.ok) return r;
    } catch {}
  }
  throw new Error('Не удалось загрузить файл');
}
function cached(key, make){
  if (mediaReady.has(key)) return Promise.resolve(mediaReady.get(key));
  if (mediaPending.has(key)) return mediaPending.get(key);
  const p = make().then(u => { mediaReady.set(key, u); return u; });
  mediaPending.set(key, p);
  p.finally(() => mediaPending.delete(key)).catch(() => {});
  return p;
}
const fetchMedia = (mxc, thumb) => cached(mxc + '|' + (thumb || 'full'), async () => URL.createObjectURL(await (await rawDownload(mxc, thumb)).blob()));
const safeMime = m => /^(image\/(png|jpeg|gif|webp)|audio\/[\w.+-]+|video\/[\w.+-]+)$/i.test(String(m || '').split(';')[0]) ? String(m).split(';')[0] : 'application/octet-stream';
const fetchEncrypted = (file, mime) => cached(file.url + '|enc', async () => {
  const data = await (await rawDownload(file.url, null)).arrayBuffer();
  const plain = await decryptAttachment(data, file);
  return URL.createObjectURL(new Blob([plain], {type:safeMime(mime || file.mimetype)}));
});
function eventFromEl(el){
  const room = S.client.getRoom(el.dataset.room);
  return room?.findEventById(el.dataset.ev) || null;
}
function hydrate(root){
  root.querySelectorAll('img[data-mxc]:not([src])').forEach(img => {
    fetchMedia(img.dataset.mxc, img.dataset.thumb ? +img.dataset.thumb : null).then(u => { img.src = u; }).catch(() => {});
  });
  root.querySelectorAll('img[data-ev]:not([src])').forEach(img => {
    const ev = eventFromEl(img), c = ev?.getContent();
    if (c?.file) fetchEncrypted(c.file, c.info?.mimetype).then(u => { img.src = u; }).catch(() => {});
  });
}

/* ---------- room helpers ---------- */
const membership = room => room.getMyMembership();
const isEncrypted = room => !!(room.hasEncryptionStateEvent?.() ?? room.currentState.getStateEvents('m.room.encryption', ''));
function dmPartnerOf(room){
  for (const [u, ids] of Object.entries(S.dm)) if (Array.isArray(ids) && ids.includes(room.roomId)) return u;
  return room.getDMInviter?.() || null;
}
function isDM(room){
  if (dmPartnerOf(room)) return true;
  const named = room.currentState.getStateEvents('m.room.name', '')?.getContent()?.name || room.getCanonicalAlias();
  return !named && room.getInvitedAndJoinedMemberCount() <= 2;
}
const noMxid = t => String(t || '').replace(/@([^:\s]+):[^\s,]+/g, '$1');
function roomName(room){
  const n = noMxid(room.name || '');
  if (!n || /^Empty room/.test(n)) return 'Пустой чат';
  return n.replace(/^(.*) and (\d+) others?$/, '$1 и ещё $2').replace(/ and /g, ' и ');
}
function memberName(room, uid){ return noMxid(room.getMember(uid)?.name) || (uid === S.userId && S.me.name) || localpart(uid); }
function avatarHTML(mxc, seed, label, size){
  const ready = mxc && mediaReady.get(mxc + '|96');
  return `<div class="av" style="--c:${color(seed)};--s:${size}px">${esc(initials(label))}${mxc ? `<img alt="" data-mxc="${esc(mxc)}" data-thumb="96"${ready ? ` src="${ready}"` : ''}>` : ''}</div>`;
}
function roomAvatar(room, size){
  const name = roomName(room);
  const own = room.getMxcAvatarUrl();
  if (own) return avatarHTML(own, room.roomId, name, size);
  if (isDM(room)) {
    const p = dmPartnerOf(room) || room.getAvatarFallbackMember()?.userId;
    const m = p && room.getMember(p);
    return avatarHTML(m?.getMxcAvatarUrl() || '', p || room.roomId, name, size);
  }
  return avatarHTML('', room.roomId, name, size);
}
const relOf = ev => ev.getWireContent()?.['m.relates_to'] || ev.getContent()?.['m.relates_to'];
function isMsg(ev){
  const t = ev.getType();
  if (t !== 'm.room.message' && t !== 'm.room.encrypted' && t !== 'm.sticker') return false;
  return relOf(ev)?.rel_type !== 'm.replace';
}
function svcText(room, ev){
  const callT = callText(room, ev); if (callT) return callT;
  if (!ev.isState()) return null;
  const c = ev.getContent() || {}, p = ev.getPrevContent() || {}, sk = ev.getStateKey();
  const who = memberName(room, ev.getSender());
  switch (ev.getType()) {
    case 'm.room.create': return `${who} создал(а) чат`;
    case 'm.room.name': return c.name ? `${who} изменил(а) название на «${c.name}»` : `${who} удалил(а) название`;
    case 'm.room.topic': return `${who} изменил(а) описание`;
    case 'm.room.encryption': return `${who} включил(а) сквозное шифрование`;
    case 'ru.lastochka.autodelete': { const t = c.ttl > 0 ? c.ttl : 0; return t ? `${who} включил(а) автоудаление сообщений: ${ttlText(t)}` : `${who} выключил(а) автоудаление сообщений`; }
    case 'm.room.pinned_events': { const a = (c.pinned || []).length, b = (p.pinned || []).length; return a > b ? `${who} закрепил(а) сообщение` : a < b ? `${who} открепил(а) сообщение` : null; }
    case 'm.room.member': {
      const target = noMxid(c.displayname || p.displayname) || localpart(sk);
      const m = c.membership, pm = p.membership;
      if (m === 'join' && pm === 'join') return c.displayname !== p.displayname ? `${p.displayname || localpart(sk)} теперь ${c.displayname || localpart(sk)}` : null;
      if (m === 'join') return `${target} присоединился(-ась) к чату`;
      if (m === 'invite') return `${who} пригласил(а) ${target}`;
      if (m === 'leave') return ev.getSender() === sk ? (pm === 'invite' ? `${target} отклонил(а) приглашение` : `${target} покинул(а) чат`) : `${who} удалил(а) ${target}`;
      if (m === 'ban') return `${who} заблокировал(а) ${target}`;
      return null;
    }
  }
  return null;
}
const visible = (room, ev) => isMsg(ev) ? !isExpired(ev) : !!svcText(room, ev);
function undecryptable(){ return S.cstate.verified ? '🔒 Не удалось расшифровать' : '🔒 Не удалось расшифровать — подтвердите этот вход'; }
function snippet(room, ev){
  if (!isMsg(ev)) return svcText(room, ev) || '';
  if (ev.isRedacted()) return 'Сообщение удалено';
  if (ev.isDecryptionFailure()) return '🔒 Не удалось расшифровать';
  if (ev.getType() === 'm.room.encrypted') return '🔒 Расшифровка…';
  if (ev.getType() === 'm.sticker') return 'Стикер';
  const c = ev.getContent();
  if (c?.msgtype === 'm.key.verification.request') return '🔐 Запрос на подтверждение';
  switch (c.msgtype) {
    case 'm.image': return '🖼 Фото' + (c.filename && c.body && c.body !== c.filename ? ', ' + c.body : '');
    case 'm.video': return '🎬 Видео';
    case 'm.audio': return '🎵 Аудио';
    case 'm.file': return '📎 ' + (c.filename || c.body || 'Файл');
    case 'm.location': return '📍 Геопозиция';
    case 'm.emote': return '* ' + memberName(room, ev.getSender()) + ' ' + (c.body || '');
  }
  return stripReply(c.body).split('\n')[0];
}
const liveEvents = room => room.getLiveTimeline().getEvents();
function lastShown(room){
  const evs = liveEvents(room);
  for (let i = evs.length - 1; i >= 0; i--) if (visible(room, evs[i])) return evs[i];
  return null;
}
function typingMembers(room){ return room.getMembers().filter(m => m.typing && m.userId !== S.userId); }
function typingText(room){
  const t = typingMembers(room);
  if (!t.length) return '';
  if (isDM(room)) return 'печатает…';
  if (t.length === 1) return t[0].name + ' печатает…';
  return plural(t.length, ['человек','человека','человек']) + ' печатают…';
}
const canSend = room => !!room && membership(room) === 'join' && (!isEncrypted(room) || !!crypto_());
const pendingStatus = ev => ev.status && ev.status !== 'sent' ? ev.status : null;
function othersReadTs(room){
  let ts = 0;
  for (const m of room.getJoinedMembers()) {
    if (m.userId === S.userId) continue;
    const id = room.getEventReadUpTo(m.userId);
    const ev = id && room.findEventById(id);
    if (ev && ev.getTs() > ts) ts = ev.getTs();
  }
  return ts;
}
function ticksFor(ev, readTs){
  const st = pendingStatus(ev);
  if (st === 'not_sent') return '<span class="fail" title="Не отправлено">!</span>';
  if (st) return I.clock;
  return ev.getTs() <= readTs ? I.double : I.check;
}

/* ---------- исчезающие сообщения (автоудаление) ---------- */
// Таймер чата хранится в состоянии комнаты (ru.lastochka.autodelete).
// Срок жизни записывается ВНУТРЬ содержимого сообщения — в зашифрованных чатах
// сервер его не видит. По истечении срока: у всех Ласточек сообщение сразу скрывается,
// а Ласточка отправителя удаляет его с сервера (redaction). Дополнительно ставится
// m.room.retention, чтобы Synapse сам стирал старые сообщения, даже если отправитель офлайн.
const TTL_EV = 'ru.lastochka.autodelete', EXP_KEY = 'ru.lastochka.expires';
const TTL_OPTS = [[0, 'Выключено'], [30e3, '30 секунд'], [300e3, '5 минут'], [3600e3, '1 час'], [864e5, '1 день'], [6048e5, '1 неделя'], [2592e6, '1 месяц']];
const ttlText = ms => (TTL_OPTS.find(o => o[0] === ms) || [0, ms ? fmtLeft(ms) : 'Выключено'])[1];
function roomTTL(room){
  const v = room?.currentState.getStateEvents(TTL_EV, '')?.getContent()?.ttl;
  return Number.isFinite(v) && v > 0 ? v : 0;
}
function expiryOf(ev){
  const c = ev.getOriginalContent?.() || ev.getContent() || {};
  const v = c[EXP_KEY];
  return Number.isFinite(v) && v > 0 ? v : 0;
}
const isExpired = ev => { const x = expiryOf(ev); return !!x && x <= Date.now(); };
function withTTL(room, content){
  const ttl = roomTTL(room);
  if (ttl) content[EXP_KEY] = Date.now() + ttl;
  return content;
}
function fmtLeft(ms){
  const s = Math.max(0, Math.ceil(ms / 1000));
  if (s < 60) return s + ' с';
  if (s < 3600) return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
  if (s < 86400) return Math.floor(s / 3600) + ' ч';
  return Math.floor(s / 86400) + ' дн';
}
const ttlBadge = ev => { const x = expiryOf(ev); return x ? `<span class="ttl" data-exp="${x}" title="Сообщение исчезнет ${esc(new Date(x).toLocaleString('ru-RU'))}">🔥${esc(fmtLeft(x - Date.now()))}</span>` : ''; };
const redactQueue = [], redactSeen = new Set();
let redacting = false;
async function drainRedactions(){
  if (redacting) return; redacting = true;
  while (redactQueue.length) {
    const [roomId, id] = redactQueue.shift();
    try { await S.client.redactEvent(roomId, id); }
    catch (e) {
      const wait = e.data?.retry_after_ms;
      if (wait) { redactQueue.unshift([roomId, id]); await new Promise(r => setTimeout(r, Math.min(wait, 30000))); continue; }
      console.warn('autodelete', e);
    }
    await new Promise(r => setTimeout(r, 300));
  }
  redacting = false;
}
let ttlSweepAt = 0;
function ttlTick(){
  if (!S.client || S.locked) return;
  const now = Date.now();
  let changed = false;
  document.querySelectorAll('.ttl[data-exp]').forEach(el => {
    const left = +el.dataset.exp - now;
    if (left <= 0) changed = true; else el.textContent = '🔥' + fmtLeft(left);
  });
  if (changed) schedule();
  if (now - ttlSweepAt < 5000) return;
  ttlSweepAt = now;
  for (const room of S.client.getRooms()) {
    if (membership(room) !== 'join') continue;
    let hiddenHere = false;
    for (const ev of liveEvents(room)) {
      const x = expiryOf(ev);
      if (!x || x > now || ev.isRedacted()) continue;
      hiddenHere = true;
      const id = ev.getId();
      if (ev.getSender() === S.userId && !pendingStatus(ev) && !String(id).startsWith('~') && !redactSeen.has(id)) {
        redactSeen.add(id); redactQueue.push([room.roomId, id]);
      }
    }
    if (hiddenHere) scheduleFor(room.roomId);
  }
  drainRedactions();
}
setInterval(ttlTick, 1000);
async function autoDeleteDialog(room){
  const cur0 = roomTTL(room);
  const v = await modal({title:'Автоудаление сообщений', html:'<p>Новые сообщения в этом чате будут исчезать у всех участников через выбранное время после отправки. Уже отправленные сообщения не изменятся.</p><p style="font-size:13px">Скриншоты и копирование до удаления предотвратить нельзя — так же, как в Telegram.</p>',
    buttons:TTL_OPTS.map(([ms, t]) => ({label:(ms === cur0 ? '✓ ' : '') + t, value:String(ms)}))});
  if (v == null || +v === cur0) return;
  const ttl = +v;
  try {
    await S.client.sendStateEvent(room.roomId, TTL_EV, ttl ? {ttl} : {}, '');
    // Серверная политика хранения: подчищает базу, даже если отправитель не в сети.
    S.client.sendStateEvent(room.roomId, 'm.room.retention', ttl ? {max_lifetime:Math.max(ttl, 3600e3)} : {}, '').catch(() => {});
    toast(ttl ? 'Автоудаление: ' + ttlText(ttl) : 'Автоудаление выключено');
  } catch (e) {
    toast(e.errcode === 'M_FORBIDDEN' ? 'Менять автоудаление могут только администраторы чата' : 'Не удалось: ' + e.message);
  }
}

/* ---------- render scheduling ---------- */
let rafPending = false, needList = false, needChat = false;
function schedule(list = true, chat = true){
  needList = needList || list; needChat = needChat || chat;
  if (rafPending) return;
  rafPending = true;
  requestAnimationFrame(() => {
    rafPending = false;
    const l = needList, c = needChat; needList = needChat = false;
    if (l) { renderList(); updateTitle(); }
    if (c && S.current && S.client.getRoom(S.current)) { renderHeader(); renderComposer(); renderTimeline(); markRead(); }
  });
}
const scheduleFor = roomId => schedule(true, roomId === S.current);

/* ---------- room list ---------- */
function rowHTML(room){
  const name = roomName(room), active = room.roomId === S.current, mem = membership(room);
  let preview, timeHTML = '', badge = '';
  if (mem === 'invite') {
    const inv = room.getMember(S.userId)?.events?.member?.getSender();
    preview = `<span class="typing">Приглашение${inv ? ' от ' + esc(memberName(room, inv)) : ''}</span>`;
  } else if (typingMembers(room).length) {
    preview = `<span class="typing">${esc(typingText(room))}</span>`;
  } else {
    const ev = lastShown(room);
    if (ev) {
      const mine = ev.getSender() === S.userId;
      const who = isMsg(ev) && (mine || !isDM(room)) ? `<span class="who">${mine ? 'Вы' : esc(memberName(room, ev.getSender()))}: </span>` : '';
      preview = who + esc(snippet(room, ev));
      timeHTML = (mine && isMsg(ev) ? `<span class="tick-blue">${ticksFor(ev, othersReadTs(room))}</span>` : '') + esc(listTime(ev.getTs()));
    } else preview = isEncrypted(room) ? '🔒 Зашифрованный чат' : '';
  }
  const draft = !active && mem === 'join' && DRAFTS.get(room.roomId);
  if (draft) preview = `<span class="draft">Черновик: </span>${esc(draft.replace(/\s+/g, ' ').slice(0, 120))}`;
  const unread = active && !document.hidden ? 0 : room.getUnreadNotificationCount('total');
  const hl = room.getUnreadNotificationCount('highlight');
  const muted = isMuted(room);
  if (unread) badge = `<span class="badge${hl ? ' mention' : ''}${muted && !hl ? ' muted' : ''}">${hl ? '@' : unread > 999 ? '999+' : unread}</span>`;
  else if (isFav(room)) badge = `<span class="fav-pin" title="Закреплён">${I.pin}</span>`;
  return `<div class="chat${active ? ' active' : ''}" data-room="${esc(room.roomId)}" role="button" tabindex="0">
    ${roomAvatar(room, 54)}
    <div class="ci"><div class="r1"><span class="t">${isEncrypted(room) ? I.lock : ''}<span style="overflow:hidden;text-overflow:ellipsis">${esc(name)}</span>${muted ? '<span class="mute-ic" title="Без звука">🔕</span>' : ''}</span><span class="time">${timeHTML}</span></div>
    <div class="r2"><span class="p">${preview}</span>${badge}</div></div></div>`;
}
// ---------- подсказки при наборе: @упоминания и :эмодзи ----------
const EMOJI_KW = Object.entries(Object.fromEntries('огонь:🔥,класс:👍,лайк:👍,ок:👌,окей:👌,да:✅,нет:❌,сердце:❤️,люблю:❤️,любовь:😍,смех:😂,ору:😂,хаха:😂,ржу:🤣,улыбка:😊,радость:😄,грусть:😢,плачу:😭,слезы:😭,злюсь:😡,злой:😠,шок:😱,ужас:😱,вау:😮,ого:😮,думаю:🤔,хм:🤔,сплю:😴,устал:😩,круто:😎,очки:😎,поцелуй:😘,обнимаю:🤗,спасибо:🙏,пожалуйста:🙏,молюсь:🙏,браво:👏,аплодисменты:👏,сила:💪,мышцы:💪,праздник:🎉,ура:🎉,поздравляю:🥳,подарок:🎁,торт:🎂,др:🎂,кофе:☕,чай:🍵,пиво:🍺,вино:🍷,еда:🍽️,пицца:🍕,бургер:🍔,деньги:💰,доллар:💵,рубль:₽,работа:💼,офис:🏢,дом:🏠,машина:🚗,самолет:✈️,самолёт:✈️,поезд:🚆,солнце:☀️,дождь:🌧️,снег:❄️,холод:🥶,жара:🥵,звезда:⭐,луна:🌙,цветок:🌸,роза:🌹,кот:🐱,котик:😺,собака:🐶,пес:🐶,мышь:🐭,заяц:🐰,лиса:🦊,медведь:🐻,панда:🐼,обезьяна:🐵,рыба:🐟,птица:🐦,ласточка:🐦,единорог:🦄,сто:💯,100:💯,ракета:🚀,бомба:💣,взрыв:💥,молния:⚡,звонок:📞,телефон:📱,компьютер:💻,почта:📧,письмо:✉️,замок:🔒,ключ:🔑,время:⏰,часы:⌚,календарь:📅,галочка:✔️,крестик:✖️,внимание:⚠️,вопрос:❓,восклицание:❗,идея:💡,книга:📚,музыка:🎵,кино:🎬,игра:🎮,мяч:⚽,футбол:⚽,победа:🏆,кубок:🏆,медаль:🥇,глаза:👀,смотрю:👀,рука:✋,привет:👋,пока:👋,кулак:👊,мир:✌️,палец:👆,вниз:👇,хорошо:👍,плохо:👎,дизлайк:👎,фейспалм:🤦,пожимаю:🤷,незнаю:🤷,тсс:🤫,секрет:🤫,болею:🤒,больной:🤒,маска:😷,клоун:🤡,призрак:👻,череп:💀,какашка:💩,дьявол:😈,ангел:😇,подмигиваю:😉,язык:😛,стесняюсь:😊,краснею:😳,скучно:😑,молчу:😶,зеваю:🥱,голодный:🤤,вкусно:😋,тошнит:🤢,сердечки:🥰,влюблен:😍,влюблён:😍,разбитое:💔,кофеек:☕,утро:🌅,ночь:🌃,спокойной:🌙,доброе:☀️,новыйгод:🎄,елка:🎄,ёлка:🎄,снеговик:⛄,хэллоуин:🎃,тыква:🎃,флаг:🏁,россия:🇷🇺,мем:🤪,безумие:🤪,срочно:🆘,стоп:🛑,запрет:🚫,повтор:🔁,вверх:⬆️,вправо:➡️,влево:⬅️'.split(',').map(p => p.split(':'))));
const AC = {items:[], idx:0, kind:'', start:0};
S.mentions = [];
function acClose(){ $('#ac').hidden = true; AC.items = []; }
function acUpdate(){
  const inp = $('#input'), pos = inp.selectionStart, before = inp.value.slice(0, pos), room = cur();
  let m;
  if (room && (m = /(^|\s)@([^\s@]{0,30})$/.exec(before))) {
    const q = norm(m[2]);
    const mem = room.getJoinedMembers().filter(x => x.userId !== S.userId)
      .map(x => ({uid:x.userId, name:memberName(room, x.userId), mxc:x.getMxcAvatarUrl?.() || ''}))
      .filter(x => !q || norm(x.name).includes(q) || norm(localpart(x.uid)).includes(q)).slice(0, 8);
    if (!mem.length) return acClose();
    AC.kind = 'at'; AC.start = pos - m[2].length - 1; AC.items = mem;
  } else if ((m = /(^|\s):([\p{L}\d]{2,20})$/u.exec(before))) {
    const q = norm(m[2]);
    const seen = new Set(), list = [];
    for (const [w, e] of EMOJI_KW) if (norm(w).startsWith(q) && !seen.has(e)) { seen.add(e); list.push({w, e}); if (list.length >= 8) break; }
    if (!list.length) return acClose();
    AC.kind = 'emo'; AC.start = pos - m[2].length - 1; AC.items = list;
  } else return acClose();
  AC.idx = Math.min(AC.idx, AC.items.length - 1);
  const ac = $('#ac');
  ac.innerHTML = AC.items.map((it, i) => AC.kind === 'at'
    ? `<button class="ac-i${i === AC.idx ? ' on' : ''}" data-i="${i}">${avatarHTML(it.mxc, it.uid, it.name, 28)}<span>${esc(it.name)}</span></button>`
    : `<button class="ac-i${i === AC.idx ? ' on' : ''}" data-i="${i}"><span class="ac-e">${it.e}</span><span>:${esc(it.w)}</span></button>`).join('');
  ac.hidden = false; hydrate(ac);
}
function acPick(i){
  const it = AC.items[i]; if (!it) return;
  const inp = $('#input'), pos = inp.selectionStart;
  const ins = AC.kind === 'at' ? it.name + ' ' : it.e + ' ';
  inp.value = inp.value.slice(0, AC.start) + ins + inp.value.slice(pos);
  const p = AC.start + ins.length; inp.setSelectionRange(p, p); inp.focus();
  if (AC.kind === 'at' && !S.mentions.some(x => x.uid === it.uid)) S.mentions.push({uid:it.uid, name:it.name});
  if (AC.kind === 'emo') pushRecent?.(it.e);
  acClose(); autosize(); updateSendBtn();
}
$('#ac').addEventListener('mousedown', e => { const b = e.target.closest('[data-i]'); if (b) { e.preventDefault(); acPick(+b.dataset.i); } });
$('#input').addEventListener('input', acUpdate);
$('#input').addEventListener('blur', () => setTimeout(acClose, 150));
$('#input').addEventListener('keydown', e => {
  if ($('#ac').hidden || !AC.items.length) return;
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); e.stopImmediatePropagation(); AC.idx = (AC.idx + (e.key === 'ArrowDown' ? 1 : -1) + AC.items.length) % AC.items.length; acUpdate(); }
  else if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); e.stopImmediatePropagation(); acPick(AC.idx); }
  else if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); acClose(); }
}, true);
// упоминания в отправляемом сообщении — как в Element (m.mentions + ссылка matrix.to)
function applyMentions(content, text){
  const used = S.mentions.filter(m => text.includes(m.name));
  S.mentions = [];
  if (!used.length) return content;
  content['m.mentions'] = {user_ids:[...new Set(used.map(m => m.uid))]};
  let html = esc(text);
  for (const m of used) html = html.replace(esc(m.name), `<a href="https://matrix.to/#/${encodeURIComponent(m.uid)}">${esc(m.name)}</a>`);
  content.format = 'org.matrix.custom.html';
  content.formatted_body = html.replace(/\n/g, '<br>');
  return content;
}
// ---------- черновики (только в памяти: на диск текст не попадает) ----------
const DRAFTS = new Map();
function saveDraft(){
  if (!S.current || S.editing) return;
  const t = $('#input').value;
  if (t.trim()) DRAFTS.set(S.current, t); else DRAFTS.delete(S.current);
}
// ---------- закреплённые, без звука, папки ----------
const isFav = room => !!room.tags?.['m.favourite'];
function isMuted(room){
  const pr = S.client?.pushRules?.global;
  if (pr?.override?.some(r => r.rule_id === room.roomId && r.enabled !== false && !(r.actions || []).includes('notify'))) return true;
  return !!pr?.room?.some(r => r.rule_id === room.roomId && r.enabled !== false && (!(r.actions || []).length || r.actions.includes('dont_notify')));
}
S.folder = 'all';
const FOLDERS = [['all', 'Все'], ['dm', 'Личные'], ['group', 'Группы'], ['unread', 'Непрочитанные']];
function inFolder(r, f){
  if (f === 'dm') return isDM(r);
  if (f === 'group') return !isDM(r);
  if (f === 'unread') return membership(r) === 'invite' || r.getUnreadNotificationCount('total') > 0 || r.roomId === S.current;
  return true;
}
function renderFolders(){
  const nav = $('#folders'); if (!nav || !S.client) return;
  const rooms = S.client.getRooms().filter(r => !r.isSpaceRoom() && ['join', 'invite'].includes(membership(r)));
  nav.innerHTML = FOLDERS.map(([id, t]) => {
    const n = id === 'all' ? 0 : rooms.filter(r => inFolder(r, id) && !isMuted(r) && r.getUnreadNotificationCount('total') > 0).length;
    return `<button class="${S.folder === id ? 'on' : ''}" data-fold="${id}">${t}${n ? `<i>${n}</i>` : ''}</button>`;
  }).join('');
}
$('#folders').addEventListener('click', e => { const b = e.target.closest('[data-fold]'); if (!b) return; S.folder = b.dataset.fold; $('#list').scrollTop = 0; renderList(); });
function openListCtx(x, y, roomId){
  const room = S.client.getRoom(roomId); if (!room) return;
  const mem = membership(room);
  let h = '';
  if (mem === 'join') {
    h += `<button class="mi" data-lc="fav">${I.pin}${isFav(room) ? 'Открепить' : 'Закрепить сверху'}</button>`;
    h += `<button class="mi" data-lc="mute">${isMuted(room) ? I_('bell') : I_('mute')}${isMuted(room) ? 'Включить уведомления' : 'Без звука'}</button>`;
    if (room.getUnreadNotificationCount('total') > 0) h += `<button class="mi" data-lc="read">${I_('check')}Пометить прочитанным</button>`;
  }
  h += `<button class="mi danger" data-lc="del">${I.trash}${mem === 'invite' ? 'Отклонить приглашение' : isDM(room) ? 'Удалить чат' : 'Покинуть группу'}</button>`;
  const m = $('#lctx'); m.innerHTML = h; m.hidden = false; m.dataset.room = roomId;
  const w = m.offsetWidth, hh = m.offsetHeight;
  m.style.left = Math.max(8, Math.min(x, innerWidth - w - 8)) + 'px';
  m.style.top = Math.max(8, Math.min(y, innerHeight - hh - 8)) + 'px';
}
$('#lctx').addEventListener('click', async e => {
  const b = e.target.closest('[data-lc]'); if (!b) return;
  const m = $('#lctx'), room = S.client.getRoom(m.dataset.room); m.hidden = true;
  if (!room) return;
  const a = b.dataset.lc;
  try {
    if (a === 'fav') { if (isFav(room)) await S.client.deleteRoomTag(room.roomId, 'm.favourite'); else await S.client.setRoomTag(room.roomId, 'm.favourite', {order:0.5}); }
    else if (a === 'mute') {
      if (isMuted(room)) {
        for (const kind of ['override', 'room']) if (S.client.pushRules?.global?.[kind]?.some(r => r.rule_id === room.roomId)) await S.client.deletePushRule('global', kind, room.roomId).catch(() => {});
        toast('Уведомления включены');
      } else {
        await S.client.addPushRule('global', 'override', room.roomId, {conditions:[{kind:'event_match', key:'room_id', pattern:room.roomId}], actions:[]});
        toast('Чат без звука');
      }
      S.client.pushRules = await S.client.getPushRules().catch(() => S.client.pushRules);
    }
    else if (a === 'read') { const ev = room.getLiveTimeline().getEvents().slice(-1)[0]; if (ev) await S.client.sendReadReceipt(ev); }
    else if (a === 'del') {
      const dm = isDM(room), inv = membership(room) === 'invite';
      if (!inv) {
        const ok = await modal({title:dm ? 'Удалить чат?' : 'Покинуть группу?', html:`<p>${dm ? 'Чат пропадёт из списка. Собеседник его не потеряет.' : 'Вы перестанете получать сообщения этой группы. Вернуться можно только по новому приглашению, если группа закрытая.'}</p>`, buttons:[{label:'Отмена'}, {label:dm ? 'Удалить' : 'Покинуть', value:true, danger:true}]});
        if (!ok) return;
      }
      await S.client.leave(room.roomId);
      await S.client.forget(room.roomId).catch(() => {});
      DRAFTS.delete(room.roomId);
      if (S.current === room.roomId) closeChat();
    }
  } catch (err) { toast('Не удалось: ' + (err.message || err)); }
  schedule();
});
$('#list').addEventListener('contextmenu', e => {
  const r = e.target.closest('[data-room]'); if (!r) return;
  e.preventDefault(); openListCtx(e.clientX, e.clientY, r.dataset.room);
});
document.addEventListener('mousedown', e => { if (!$('#lctx').hidden && !e.target.closest('#lctx')) $('#lctx').hidden = true; });
function sortTs(room){ const ev = lastShown(room); return ev ? ev.getTs() : Math.max(0, room.getLastActiveTimestamp()); }
function renderList(){
  const list = $('#list'), q = S.search.trim().toLowerCase();
  if (!S.client) return;
  const rooms = S.client.getRooms()
    .filter(r => !r.isSpaceRoom() && ['join', 'invite'].includes(membership(r)))
    .filter(r => !q || roomName(r).toLowerCase().includes(q) || (r.getCanonicalAlias() || '').toLowerCase().includes(q))
    .filter(r => q || inFolder(r, S.folder))
    .map(r => [r, sortTs(r)])
    .sort((a, b) => (membership(b[0]) === 'invite') - (membership(a[0]) === 'invite') || isFav(b[0]) - isFav(a[0]) || b[1] - a[1])
    .map(x => x[0]);
  renderFolders();
  if (!rooms.length) {
    const hits = q.length >= 2 ? hitsHTML(S.search.trim()) : '';
    list.innerHTML = hits || `<div class="empty">${!S.initialDone ? 'Загрузка чатов…' : q ? 'Ничего не найдено' : S.folder !== 'all' ? 'В этой папке пока пусто' : 'Чатов пока нет. Нажмите ✎ внизу, чтобы начать.'}</div>`;
    if (hits) hydrate(list);
    return;
  }
  list.innerHTML = rooms.map(rowHTML).join('') + (q.length >= 2 ? hitsHTML(S.search.trim()) : '');
  hydrate(list);
}
function updateTitle(){
  let n = 0;
  for (const r of S.client?.getRooms() || []) if (membership(r) === 'join') n += r.getUnreadNotificationCount('total') || 0;
  document.title = n ? `(${n}) Ласточка` : 'Ласточка';
}

/* ---------- chat view ---------- */
function cur(){ return S.current ? S.client.getRoom(S.current) : null; }
function openRoom(id){
  S.settingsNav = false;
  const room = S.client.getRoom(id);
  if (!room) return;
  cancelRecording(); closePicker(); if (S.current !== id) { S.find = null; $('#sbar').hidden = true; $('#sres').hidden = true; }
  saveDraft();
  S.current = id; S.reply = null; S.editing = null;
  document.body.classList.add('has-chat');
  $('#nochat').hidden = true; $('#chatview').hidden = false;
  $('#input').value = DRAFTS.get(id) || ''; autosize(); updateSendBtn();
  S.newFrom = null;
  if (room.getUnreadNotificationCount('total') > 0) {
    const evs = liveEvents(room), readId = room.getEventReadUpTo(S.userId);
    const i = readId ? evs.findIndex(e => e.getId() === readId) : -1;
    const first = evs.slice(i + 1).find(e => isMsg(e) && e.getSender() !== S.userId);
    if (first && i >= 0) S.newFrom = {room:id, ev:first.getId()};
  }
  renderList(); renderHeader(); renderComposer(); renderBar();
  renderTimeline(S.newFrom ? 'unread' : 'end');
  if (canSend(room) && matchMedia('(pointer:fine)').matches) $('#input').focus();
  room.loadMembersIfNeeded?.().catch(() => {});
  fillIfShort(room).then(markRead);
}
function closeChat(){
  saveDraft();
  cancelRecording(); closePicker(); S.find = null; $('#sbar').hidden = true; $('#sres').hidden = true;
  S.current = null;
  document.body.classList.remove('has-chat');
  $('#chatview').hidden = true; $('#nochat').hidden = false;
  renderList();
}
async function fillIfShort(room){
  for (let i = 0; i < 4; i++) {
    const box = $('#messages');
    if (S.current !== room.roomId || uiOf(room.roomId).reachedStart || box.scrollHeight > box.clientHeight + 100) break;
    await older(room);
  }
}
// Предупреждение о смене ключей собеседника — как в Element: если у человека сменилась
// «личность» шифрования (новый вход без подтверждения, сброс ключей или подмена), показываем
// плашку. Если он был подтверждён — это тревога: подтверждение надо отозвать или пройти заново.
let idBarAt = 0, idBarRoom = '';
async function renderIdBar(force){
  const bar = $('#idbar'), room = cur(), c = crypto_();
  if (!bar) return;
  if (!force && room && idBarRoom === room.roomId && Date.now() - idBarAt < 15e3) return;
  idBarAt = Date.now(); idBarRoom = room?.roomId || '';
  if (!room || !c || !isEncrypted(room) || membership(room) !== 'join') { bar.hidden = true; return; }
  const rid = room.roomId;
  await room.loadMembersIfNeeded?.().catch(() => {});
  const ids = room.getJoinedMembers().map(m => m.userId).filter(u => u !== S.userId).slice(0, 60);
  let warn = null;
  for (const uid of ids) {
    let st; try { st = await c.getUserVerificationStatus(uid); } catch { continue; }
    if (st?.wasCrossSigningVerified?.() && !st.isCrossSigningVerified?.()) { warn = {uid, bad:true}; break; }
    if (st?.needsUserApproval && !warn) warn = {uid, bad:false};
  }
  if (S.current !== rid) return;
  if (!warn) { bar.hidden = true; bar.innerHTML = ''; return; }
  const name = esc(memberName(room, warn.uid));
  bar.className = 'idbar' + (warn.bad ? ' bad' : '');
  bar.innerHTML = warn.bad
    ? `<span>⛔ <b>${name}</b> был(а) подтверждён(а), но его (её) ключи шифрования изменились. Возможна подмена — не пишите ничего важного, пока не проверите лично.</span><button class="btn-flat" data-idv="${esc(warn.uid)}">Подтвердить заново</button><button class="btn-flat danger" data-idw="${esc(warn.uid)}">Отозвать подтверждение</button>`
    : `<span>⚠️ У <b>${name}</b> сменились ключи шифрования — например, после переустановки или нового входа. Если не уверены, уточните у собеседника лично.</span><button class="btn-flat" data-idp="${esc(warn.uid)}">Понятно</button>`;
  bar.hidden = false;
}
$('#idbar').addEventListener('click', async e => {
  const c = crypto_(), b = e.target.closest('button'); if (!b || !c) return;
  try {
    if (b.dataset.idp) await c.pinCurrentUserIdentity(b.dataset.idp);
    else if (b.dataset.idw) await c.withdrawVerificationRequirement(b.dataset.idw);
    else if (b.dataset.idv) { const room = cur(); verifyFlow(await c.requestVerificationDM(b.dataset.idv, room.roomId)); return; }
  } catch (err) { toast('Не удалось: ' + (err.message || err)); }
  renderIdBar(true);
});
function presenceText(uid){
  const u = uid && S.client.getUser(uid);
  if (!u) return 'личный чат';
  if (u.presence === 'online' || u.currentlyActive) return 'в сети';
  const ago = u.lastActiveAgo, at = u.lastPresenceTs;
  if (ago == null || !at) return 'личный чат';
  const ms = Date.now() - (at - ago) > 0 ? Date.now() - at + ago : ago;
  const m = Math.round(ms / 60e3);
  return m < 1 ? 'был(а) только что' : m < 60 ? `был(а) ${m} мин назад` : m < 1440 ? `был(а) ${Math.round(m / 60)} ч назад` : 'был(а) давно';
}
function renderHeader(){
  const room = cur(); if (!room) return;
  $('#chat-avatar').innerHTML = roomAvatar(room, 42);
  hydrate($('#chat-avatar'));
  $('#chat-title').innerHTML = (isEncrypted(room) ? I.lock : '') + `<span style="overflow:hidden;text-overflow:ellipsis">${esc(roomName(room))}</span>`;
  let sub;
  if (typingMembers(room).length) sub = `<span class="typing">${esc(typingText(room))}</span>`;
  else if (membership(room) === 'invite') sub = 'приглашение';
  else if (isDM(room)) sub = esc(presenceText(dmPartnerOf(room) || room.getAvatarFallbackMember()?.userId));
  else sub = esc(plural(room.getJoinedMemberCount(), ['участник','участника','участников']));
  const ttl = roomTTL(room);
  if (ttl && membership(room) === 'join') sub += ` · <span class="ttl-sub">🔥 ${esc(ttlText(ttl))}</span>`;
  $('#chat-sub').innerHTML = sub;
  updateCallBtns();
  $('#input').placeholder = ttl ? `Исчезнет через ${({3600e3:'час', 864e5:'день', 6048e5:'неделю', 2592e6:'месяц'})[ttl] || ttlText(ttl)}` : 'Сообщение';
  renderPinbar();
  renderIdBar();
}
function renderComposer(){
  const room = cur(), lock = $('#lockbar');
  if (!room) return;
  const show = canSend(room);
  $('#composer').hidden = !show; $('#send').hidden = !show;
  lock.hidden = show;
  if (show) return;
  if (membership(room) === 'invite') {
    const inv = room.getMember(S.userId)?.events?.member?.getSender();
    lock.innerHTML = `<span>${esc(inv ? memberName(room, inv) : 'Вас')} приглашает вас в этот чат</span><button data-act="accept">Принять</button><button class="danger" data-act="decline">Отклонить</button>`;
  } else if (isEncrypted(room)) {
    lock.innerHTML = `<span>${I.lock}</span><span>Шифрование не запустилось в этом браузере. Откройте клиент по https или с localhost.</span>`;
  }
}
function renderTimeline(mode){
  const room = cur(); if (!room) return;
  const box = $('#messages'), ui = uiOf(room.roomId);
  const fromBottom = box.scrollHeight - box.scrollTop;
  const atBottom = fromBottom - box.clientHeight < 80;
  const items = liveEvents(room).filter(ev => visible(room, ev));
  const group = !isDM(room), readTs = othersReadTs(room);
  let html = ui.loadingOlder ? '<div class="loader">Загрузка…</div>' : ui.reachedStart && items.length ? '<div class="svc"><span>Начало истории</span></div>' : '';
  let prevDay = '', prev = null;
  const brk = (a, b) => !a || !b || !isMsg(a) || !isMsg(b) || a.getSender() !== b.getSender() || Math.abs(b.getTs() - a.getTs()) > 300000 || dayKey(a.getTs()) !== dayKey(b.getTs());
  items.forEach((ev, i) => {
    const day = dayKey(ev.getTs());
    if (day !== prevDay) { html += `<div class="date" data-ts="${ev.getTs()}"><span>${esc(fmtDay(ev.getTs()))}</span></div>`; prevDay = day; }
    if (!isMsg(ev)) { html += `<div class="svc" data-ts="${ev.getTs()}"><span>${esc(svcText(room, ev))}</span></div>`; prev = ev; return; }
    if (ev.getContent()?.msgtype === 'm.key.verification.request') {
      const who = ev.getSender() === S.userId ? 'Вы' : memberName(room, ev.getSender());
      html += `<div class="svc" data-ts="${ev.getTs()}"><span>🔐 ${esc(who)}: запрос на подтверждение ключей</span></div>`; prev = ev; return;
    }
    if (S.newFrom?.room === room.roomId && S.newFrom.ev === ev.getId()) html += '<div class="newsep" id="newsep"><span>Новые сообщения</span></div>';
    html += msgHTML(room, ev, brk(prev, ev), brk(ev, items[i + 1]), group, readTs);
    prev = ev;
  });
  for (const up of S.uploads.get(room.roomId) || []) html += uploadHTML(up);
  if (!items.length && !ui.loadingOlder) html += `<div class="svc" style="margin-top:40vh"><span>Сообщений пока нет</span></div>`;
  box.innerHTML = `<div class="tl">${html}</div>`;
  if (mode === 'keep-bottom') box.scrollTop = box.scrollHeight - fromBottom;
  else if (mode === 'unread' && $('#newsep')) box.scrollTop += $('#newsep').getBoundingClientRect().top - box.getBoundingClientRect().top - 80;
  else if (mode === 'end' || atBottom) box.scrollTop = box.scrollHeight;
  hydrate(box);
  updateDown();
  paintPlayer();
  if (S.find?.q) markTerm(box, S.find.q);
}
function uploadHTML(up){
  const inner = up.src
    ? `<div class="photo" style="width:${Math.round(Math.min(360, Math.max(140, (up.w || 400) * Math.min(1, 360 / (up.h || 300)))))}px;aspect-ratio:${up.w || 4}/${up.h || 3}"><img alt="" src="${up.src}"></div><span class="meta">${I.clock}</span>`
    : `<div class="file"><div class="ic">${I.doc}</div><div style="min-width:0"><div class="fn">${esc(up.name)}</div><div class="fs">Загрузка…</div></div></div>`;
  return `<div class="row out first last upl"><div class="bubble ${up.src ? 'media media-only' : ''}">${inner}${up.src ? '' : TAIL}</div></div>`;
}
const spacer = (edited, out, sh, ttl) => `<span class="sp" style="width:${44 + (edited ? 30 : 0) + (out ? 20 : 0) + (sh ? 17 : 0) + (ttl ? 50 : 0)}px"></span>`;
function fmtDur(ms){ const s = Math.max(0, Math.round((ms || 0) / 1000)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); }
function reactsHTML(room, ev, SP){
  const rel = room.relations?.getChildEventsForEvent(ev.getId(), 'm.annotation', 'm.reaction');
  const groups = rel?.getSortedAnnotationsByKey?.() || [];
  const chips = [];
  for (const [key, set] of groups) {
    const evs = [...set].filter(e => !e.isRedacted());
    if (!evs.length) continue;
    const mine = evs.some(e => e.getSender() === S.userId);
    chips.push(`<button class="rc${mine ? ' mine' : ''}" data-react="${esc(key)}" title="${esc(evs.map(e => memberName(room, e.getSender())).join(', '))}">${esc(key)}${evs.length > 1 ? ' ' + evs.length : ''}</button>`);
  }
  return chips.length ? `<div class="reacts">${chips.join('')}${SP}</div>` : '';
}
function voiceHTML(ev, c, SP){
  const id = ev.getId();
  const a = c['org.matrix.msc1767.audio'] || {};
  const dur = c.info?.duration || a.duration || 0;
  const isVoice = !!(c['org.matrix.msc3245.voice'] || c['org.matrix.msc2516.voice']);
  const wf = Array.isArray(a.waveform) && a.waveform.length ? a.waveform : null;
  const N = 36, bars = [];
  for (let i = 0; i < N; i++) {
    let v;
    if (wf) {
      const a0 = Math.floor(i * wf.length / N), a1 = Math.max(a0 + 1, Math.floor((i + 1) * wf.length / N));
      v = 0; for (let j = a0; j < a1 && j < wf.length; j++) v = Math.max(v, +wf[j] || 0);
      v /= 1024;
    } else v = ((hash(id + i) % 70) + 20) / 100;
    bars.push(`<i style="height:${Math.round(15 + Math.min(1, Math.max(0, v)) * 85)}%"></i>`);
  }
  const name = c.filename || c.body || 'Аудио';
  return `<div class="voice" data-voice="${esc(id)}" data-dur="${dur}"><button class="vplay" aria-label="Воспроизвести">${I.play}</button><div class="vbody">${isVoice ? '' : `<div class="fn">${esc(name)}</div>`}<div class="vwave">${bars.join('')}</div><div class="vtime">${fmtDur(dur)}<button class="vspeed" data-vspeed title="Скорость">${P.rate}×</button>${SP}</div></div></div>`;
}
function msgHTML(room, ev, first, last, group, readTs){
  const sender = ev.getSender(), out = sender === S.userId, id = ev.getId();
  const redacted = ev.isRedacted();
  const c = ev.getContent() || {};
  const edited = !redacted && !!ev.replacingEventId();
  const cls = ['row', out ? 'out' : 'in'];
  if (first) cls.push('first'); if (last) cls.push('last');
  const nameHTML = (group && !out && first ? `<div class="name" style="color:${color(sender)}">${esc(memberName(room, sender))}</div>` : '') + '<!--fwd-->';
  const avSlot = group && !out ? (last ? avatarHTML(room.getMember(sender)?.getMxcAvatarUrl() || '', sender, memberName(room, sender), 34) : '<div class="av-slot"></div>') : '';
  const tail = last ? TAIL : '';
  const shH = shieldHTML(room, ev);
  const SP = spacer(edited, out, !!shH, !!expiryOf(ev));
  const meta = `<span class="meta">${ttlBadge(ev)}${shH}${edited ? 'изм. ' : ''}${esc(fmtTime(ev.getTs()))}${out ? ticksFor(ev, readTs) : ''}</span>`;
  let replyHTML = '';
  const rid = !redacted && (ev.replyEventId || ev.getOriginalContent?.()?.['m.relates_to']?.['m.in_reply_to']?.event_id);
  if (rid) {
    const r = room.findEventById(rid);
    replyHTML = `<div class="reply" data-jump="${esc(rid)}" style="--rc:${r ? color(r.getSender()) : 'var(--accent)'}"><b>${r ? esc(memberName(room, r.getSender())) : 'Ответ'}</b><span>${r ? esc(snippet(room, r)) : 'Сообщение не загружено'}</span></div>`;
  }
  const reacts = redacted ? '' : reactsHTML(room, ev, SP);
  const fwd = c['mxtg.forwarded'] && !redacted ? `<div class="fwd">Переслано от <b>${esc(c['mxtg.forwarded'].name || localpart(c['mxtg.forwarded'].sender))}</b></div>` : '';
  const pinned = pinnedIds(room).includes(id) ? `<span class="pinmark" title="Закреплено">${I.pin}</span>` : '';
  const more = String(id).startsWith('~') ? '' : `<button class="mbtn" data-more aria-label="Действия с сообщением">${I.dots}</button>`;
  const wrap = (bcls, inner) => `<div class="${cls.join(' ')}" data-id="${esc(id)}" data-ts="${ev.getTs()}">${avSlot}<div class="bubble ${bcls}">${pinned}${inner.replace('<!--fwd-->', () => fwd)}${tail}</div>${more}</div>`;
  const textBlock = (html, extra = '') => `<div class="text ${extra}">${html}${reacts ? '' : SP}</div>${reacts}${meta}`;
  const mediaAttrs = (thumb) => c.file
    ? ` data-ev="${esc(id)}" data-room="${esc(room.roomId)}"`
    : c.url ? ` data-mxc="${esc(c.url)}"${thumb ? ` data-thumb="${thumb}"` : ''}` : '';
  const readySrc = (thumb) => c.file ? mediaReady.get(c.file.url + '|enc') : c.url && mediaReady.get(c.url + '|' + thumb);

  if (redacted) return wrap('', nameHTML + textBlock('Сообщение удалено', 'deleted'));
  if (ev.isDecryptionFailure()) return wrap('', nameHTML + textBlock(esc(undecryptable()), 'deleted'));
  if (ev.getType() === 'm.room.encrypted') return wrap('', nameHTML + textBlock('🔒 Расшифровка…', 'deleted'));
  if (ev.getType() === 'm.sticker') {
    const src = readySrc(360);
    return wrap('sticker', `<img alt="${esc(c.body || 'Стикер')}"${src ? ` src="${src}"` : mediaAttrs(360)}>${meta}`);
  }
  const mt = c.msgtype;
  if (mt === 'm.image') {
    const w = c.info?.w || 400, h = c.info?.h || 300;
    const dispW = Math.min(360, Math.max(140, w * Math.min(1, 360 / h)));
    const caption = c.filename && c.body && c.body !== c.filename ? c.body : '';
    const src = readySrc(800);
    const full = c.file ? ` data-full-ev="${esc(id)}"` : ` data-full="${esc(c.url || '')}"`;
    const img = `<div class="photo"${full} style="width:${Math.round(dispW)}px;aspect-ratio:${w}/${h}"><img alt="${esc(c.body || 'Фото')}"${src ? ` src="${src}"` : mediaAttrs(800)}>${String(id).startsWith('~') ? '' : `<button class="ph-more" data-more aria-label="Действия с фото">${I.dots}</button>`}</div>`;
    cls.push('has-photo');
    const bcls = ['media', caption || reacts ? 'has-cap' : 'media-only', nameHTML ? 'has-name' : ''].join(' ');
    return wrap(bcls, nameHTML + (replyHTML ? `<div class="cap">${replyHTML}</div>` : '') + img + (caption ? `<div class="cap">${textBlock(linkify(esc(caption)))}</div>` : reacts ? `<div class="cap">${reacts}${meta}</div>` : meta));
  }
  if (mt === 'm.audio') return wrap('', nameHTML + replyHTML + voiceHTML(ev, c, reacts ? '' : SP) + reacts + meta);
  if (mt === 'm.video') {
    const fname = c.filename || c.body || 'Видео';
    const sub = [c.info?.duration ? fmtDur(c.info.duration) : '', fmtSize(c.info?.size)].filter(Boolean).join(', ');
    return wrap('', nameHTML + replyHTML + `<div class="file vid" data-video-ev="${esc(id)}"><div class="ic">${I.play}</div><div style="min-width:0"><div class="fn">${esc(fname)}</div><div class="fs">${esc(sub)}${reacts ? '' : SP}</div></div></div>${reacts}${meta}`);
  }
  if (mt === 'm.file') {
    const fname = c.filename || c.body || 'Файл';
    return wrap('', nameHTML + replyHTML + `<div class="file" data-dl-ev="${esc(id)}" title="Скачать"><div class="ic">${I.download}</div><div style="min-width:0"><div class="fn">${esc(fname)}</div><div class="fs">${esc(fmtSize(c.info?.size))}${reacts ? '' : SP}</div></div></div>${reacts}${meta}`);
  }
  if (mt === 'm.location') {
    const geo = String(c.geo_uri || '').replace(/^geo:/, '').split(';')[0].split(',');
    const link = geo.length === 2 ? `<a href="https://www.openstreetmap.org/?mlat=${enc(geo[0])}&mlon=${enc(geo[1])}" target="_blank" rel="noopener">📍 ${esc(c.body || 'Геопозиция')}</a>` : esc(c.body || 'Геопозиция');
    return wrap('', nameHTML + replyHTML + textBlock(link));
  }
  let body = stripReply(c.body);
  if (mt === 'm.emote') body = '* ' + memberName(room, sender) + ' ' + body;
  const big = !replyHTML && !reacts && isEmojiOnly(body);
  return wrap('', nameHTML + replyHTML + textBlock(linkify(esc(body)), (big ? 'big ' : '') + (mt === 'm.notice' ? 'notice' : '')));
}

/* ---------- message security indicators ---------- */
const shields = new Map(), shieldPending = new Set();
function shieldFor(ev){
  const id = ev.getId();
  if (shields.has(id)) return shields.get(id);
  const c = crypto_();
  if (!c || shieldPending.has(id) || ev.status) return null;
  shieldPending.add(id);
  c.getEncryptionInfoForEvent(ev).then(info => shields.set(id, info || null)).catch(() => shields.set(id, null))
    .finally(() => { shieldPending.delete(id); schedule(false, true); });
  return null;
}
const SHIELD_C = CA.EventShieldColour || {NONE:0, GREY:1, RED:2};
const SHIELD_TEXT = {
  UNVERIFIED_IDENTITY:'Личность отправителя не подтверждена',
  UNSIGNED_DEVICE:'Отправитель не подтвердил устройство, с которого написал',
  UNKNOWN_DEVICE:'Сообщение отправлено с неизвестного или удалённого устройства',
  AUTHENTICITY_NOT_GUARANTEED:'Подлинность не гарантирована: ключ получен из резервной копии или переслан',
  MISMATCHED_SENDER_KEY:'Ключ отправителя не совпадает — возможна подмена',
  SENT_IN_CLEAR:'Сообщение отправлено без шифрования',
  VERIFICATION_VIOLATION:'Ключи подтверждённого собеседника изменились',
};
function shieldReasonText(info){
  if (!info) return 'Нет данных';
  if (info.shieldColour === SHIELD_C.NONE) return 'Подлинность подтверждена: устройство отправителя подписано его владельцем';
  const name = CA.EventShieldReason?.[info.shieldReason];
  return SHIELD_TEXT[name] || (info.shieldColour === SHIELD_C.RED ? 'Есть проблема с проверкой отправителя' : 'Подлинность не гарантирована');
}
function shieldHTML(room, ev){
  if (pendingStatus(ev) || ev.isRedacted() || String(ev.getId()).startsWith('~')) return '';
  if (!ev.isEncrypted()) return isEncrypted(room) ? `<span class="sh clear" title="Отправлено без шифрования">${I.warn}</span>` : '';
  if (ev.isDecryptionFailure() || ev.getType() === 'm.room.encrypted') return '';
  const info = shieldFor(ev);
  if (!info || info.shieldColour === SHIELD_C.NONE) return '';
  return `<span class="sh ${info.shieldColour === SHIELD_C.RED ? 'red' : 'grey'}" title="${esc(shieldReasonText(info))}">${I.warn}</span>`;
}
function updateDown(){ const box = $('#messages'); $('#down').hidden = box.scrollHeight - box.scrollTop - box.clientHeight < 300; }
async function older(room){
  const ui = uiOf(room.roomId);
  if (ui.loadingOlder || ui.reachedStart || membership(room) !== 'join' || Date.now() - ui.failAt < 5000) return;
  ui.loadingOlder = true;
  if (S.current === room.roomId) renderTimeline('keep-bottom');
  try {
    const more = await S.client.paginateEventTimeline(room.getLiveTimeline(), {backwards:true, limit:50});
    if (!more) ui.reachedStart = true;
  } catch (e) {
    ui.failAt = Date.now();
    if (e.httpStatus === 403) ui.reachedStart = true; else toast('Не удалось загрузить историю: ' + e.message);
  } finally { ui.loadingOlder = false; }
  if (S.current === room.roomId) renderTimeline('keep-bottom');
}
let readT;
function markRead(){
  clearTimeout(readT);
  readT = setTimeout(() => {
    const room = cur();
    if (!room || membership(room) !== 'join' || document.hidden) return;
    const box = $('#messages');
    if (box.scrollHeight - box.scrollTop - box.clientHeight > 120) return;
    const evs = liveEvents(room);
    let last = null;
    for (let i = evs.length - 1; i >= 0; i--) if (!evs[i].status && !String(evs[i].getId()).startsWith('~')) { last = evs[i]; break; }
    if (!last || S.sentReceipt.get(room.roomId) === last.getId()) return;
    S.sentReceipt.set(room.roomId, last.getId());
    S.client.sendReadReceipt(last).catch(() => {});
    renderList(); updateTitle();
  }, 400);
}
function jumpTo(id){
  const row = $('#messages').querySelector(`[data-id="${CSS.escape(id)}"]`);
  if (!row) { toast('Сообщение ещё не загружено — прокрутите вверх'); return; }
  row.scrollIntoView({block:'center', behavior:'smooth'});
  row.classList.remove('flash'); void row.offsetWidth; row.classList.add('flash');
}

/* ---------- sending ---------- */
function sendText(){
  const room = cur(); if (!canSend(room)) return;
  const inp = $('#input'); const text = inp.value.replace(/\s+$/, '');
  if (!text.trim()) return;
  inp.value = ''; autosize(); sendTyping(false); updateSendBtn();
  if (S.editing) {
    const target = S.editing; S.editing = null; renderBar(); updateSendBtn();
    S.client.sendMessage(room.roomId, {msgtype:'m.text', body:'* ' + text, 'm.new_content':{msgtype:'m.text', body:text}, 'm.relates_to':{rel_type:'m.replace', event_id:target}})
      .catch(e => toast('Не удалось изменить: ' + e.message));
    return;
  }
  let content = {msgtype:'m.text', body:text};
  if (/^\/me\s+/.test(text)) content = {msgtype:'m.emote', body:text.replace(/^\/me\s+/, '')};
  else applyMentions(content, text);
  if (S.reply) { content['m.relates_to'] = {'m.in_reply_to':{event_id:S.reply}}; S.reply = null; renderBar(); }
  S.client.sendMessage(room.roomId, withTTL(room, content)).catch(e => toast('Сообщение не отправлено: ' + e.message));
  const box = $('#messages'); requestAnimationFrame(() => { box.scrollTop = box.scrollHeight; });
  schedule();
}
async function uploadInto(room, data, name, mime, content){
  if (isEncrypted(room)) {
    const {data:cipher, info:fi} = await encryptAttachment(await data.arrayBuffer());
    const r = await S.client.uploadContent(new Blob([cipher], {type:'application/octet-stream'}), {type:'application/octet-stream', includeFilename:false});
    content.file = {...fi, url:r.content_uri, mimetype:mime};
    return r.content_uri + '|enc';
  }
  const r = await S.client.uploadContent(data, {name, type:mime});
  content.url = r.content_uri;
  return r.content_uri + '|full';
}
function addUpload(roomId, up){ const l = S.uploads.get(roomId) || []; l.push(up); S.uploads.set(roomId, l); if (S.current === roomId) renderTimeline('end'); }
function dropUpload(roomId, up){ S.uploads.set(roomId, (S.uploads.get(roomId) || []).filter(x => x !== up)); }
async function sendFile(file){
  const room = cur(); if (!canSend(room)) return;
  const mime = file.type || 'application/octet-stream';
  const isImg = /^image\/(png|jpe?g|gif|webp)$/.test(mime);
  const name = file.name || 'file';
  const info = {mimetype:mime, size:file.size};
  if (isImg) { try { const bmp = await createImageBitmap(file); info.w = bmp.width; info.h = bmp.height; bmp.close?.(); } catch {} }
  const up = {name, src:isImg ? URL.createObjectURL(file) : null, w:info.w, h:info.h};
  addUpload(room.roomId, up);
  const content = {msgtype:isImg ? 'm.image' : /^video\//.test(mime) ? 'm.video' : /^audio\//.test(mime) ? 'm.audio' : 'm.file', body:name, filename:name, info};
  if (S.reply) { content['m.relates_to'] = {'m.in_reply_to':{event_id:S.reply}}; S.reply = null; renderBar(); }
  try {
    const key = await uploadInto(room, file, name, mime, content);
    if (isImg) { mediaReady.set(key, up.src); if (content.url) mediaReady.set(content.url + '|800', up.src); }
    dropUpload(room.roomId, up);
    const p = S.client.sendMessage(room.roomId, withTTL(room, content));
    schedule();
    await p;
  } catch (e) {
    dropUpload(room.roomId, up); schedule();
    toast('Не удалось отправить «' + name + '»: ' + e.message);
  }
}

/* ---------- voice messages ---------- */
const REC = {};
function pickMime(){
  for (const m of ['audio/ogg;codecs=opus', 'audio/webm;codecs=opus', 'audio/mp4', 'audio/webm'])
    if (window.MediaRecorder?.isTypeSupported?.(m)) return m;
  return '';
}
async function startRecording(){
  const room = cur(); if (!canSend(room) || S.recording) return;
  if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) { toast('Запись звука здесь не поддерживается'); return; }
  try { REC.stream = await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true, noiseSuppression:true, autoGainControl:true}}); }
  catch { toast('Нет доступа к микрофону. Разрешите его в настройках системы (Конфиденциальность → Микрофон).'); return; }
  const mime = pickMime();
  REC.mime = mime || 'audio/webm';
  try { REC.rec = new MediaRecorder(REC.stream, mime ? {mimeType:mime, audioBitsPerSecond:32000} : undefined); }
  catch (e) { REC.stream.getTracks().forEach(t => t.stop()); toast('Не удалось начать запись: ' + e.message); return; }
  REC.chunks = []; REC.levels = []; REC.roomId = room.roomId;
  REC.rec.ondataavailable = e => { if (e.data.size) REC.chunks.push(e.data); };
  REC.rec.start(250);
  REC.start = Date.now();
  try {
    REC.ctx = new AudioContext();
    const src = REC.ctx.createMediaStreamSource(REC.stream);
    REC.analyser = REC.ctx.createAnalyser(); REC.analyser.fftSize = 512; src.connect(REC.analyser);
    const buf = new Uint8Array(REC.analyser.fftSize);
    REC.sample = setInterval(() => {
      REC.analyser.getByteTimeDomainData(buf);
      let s = 0; for (const v of buf) { const x = (v - 128) / 128; s += x * x; }
      REC.levels.push(Math.sqrt(s / buf.length));
    }, 100);
  } catch {}
  REC.timer = setInterval(updateRecTime, 250);
  S.recording = true; sendTyping(false); closePicker(); renderRecUI();
}
function stopTracks(){
  clearInterval(REC.timer); clearInterval(REC.sample);
  REC.stream?.getTracks().forEach(t => t.stop());
  REC.ctx?.close().catch(() => {}); REC.ctx = null;
}
function cancelRecording(){
  if (!S.recording) return;
  S.recording = false;
  try { REC.rec.onstop = null; REC.rec.stop(); } catch {}
  stopTracks(); renderRecUI();
}
function finishRecording(){
  if (!S.recording) return;
  S.recording = false;
  const duration = Date.now() - REC.start;
  REC.rec.onstop = () => {
    stopTracks();
    const blob = new Blob(REC.chunks, {type:REC.mime.split(';')[0]});
    if (duration < 700 || !blob.size) { toast('Слишком короткое сообщение'); return; }
    sendVoice(REC.roomId, blob, duration, waveformFrom(REC.levels));
  };
  try { REC.rec.stop(); } catch { stopTracks(); }
  renderRecUI();
}
function waveformFrom(levels){
  const N = 64;
  if (!levels.length) return Array(N).fill(200);
  const max = Math.max(...levels, 0.01), out = [];
  for (let i = 0; i < N; i++) {
    const a = Math.floor(i * levels.length / N), b = Math.max(a + 1, Math.floor((i + 1) * levels.length / N));
    let m = 0; for (let j = a; j < b && j < levels.length; j++) m = Math.max(m, levels[j]);
    out.push(Math.round(Math.min(1, m / max) * 1024));
  }
  return out;
}
function updateRecTime(){
  if (!S.recording) return;
  const ms = Date.now() - REC.start;
  $('#rec-time').textContent = fmtDur(ms);
  if (ms > 15 * 60 * 1000) finishRecording();
}
function renderRecUI(){
  $('#cin').hidden = !!S.recording;
  $('#rec').hidden = !S.recording;
  if (S.recording) $('#rec-time').textContent = '0:00';
  updateSendBtn();
}
async function sendVoice(roomId, blob, duration, waveform){
  const room = S.client.getRoom(roomId); if (!canSend(room)) return;
  const mime = blob.type || 'audio/webm';
  const ext = mime.includes('ogg') ? 'ogg' : mime.includes('mp4') ? 'm4a' : 'webm';
  const name = 'Голосовое сообщение.' + ext;
  const content = {
    msgtype:'m.audio', body:'Голосовое сообщение', filename:name,
    info:{mimetype:mime, size:blob.size, duration},
    'org.matrix.msc1767.text':'Голосовое сообщение',
    'org.matrix.msc1767.audio':{duration, waveform},
    'org.matrix.msc3245.voice':{},
  };
  if (S.reply && S.current === roomId) { content['m.relates_to'] = {'m.in_reply_to':{event_id:S.reply}}; S.reply = null; renderBar(); }
  const up = {name:'Голосовое сообщение', src:null};
  addUpload(roomId, up);
  try {
    const key = await uploadInto(room, blob, name, mime, content);
    mediaReady.set(key, URL.createObjectURL(blob));
    dropUpload(roomId, up);
    const p = S.client.sendMessage(roomId, withTTL(room, content));
    schedule();
    await p;
  } catch (e) {
    dropUpload(roomId, up); schedule();
    toast('Голосовое не отправлено: ' + e.message);
  }
}
function updateSendBtn(){
  const b = $('#send');
  const mode = S.recording || S.editing || $('#input').value.trim() ? 'send' : 'mic';
  if (b.dataset.mode === mode) return;
  b.dataset.mode = mode;
  b.innerHTML = mode === 'mic' ? I.mic : I.send;
  b.setAttribute('aria-label', mode === 'mic' ? 'Записать голосовое сообщение' : 'Отправить');
}

/* ---------- audio player ---------- */
const P = {audio:new Audio(), id:null, loading:false, rate:1};
try { P.rate = +localStorage.getItem('lastochka.vrate') || 1; } catch {}
P.audio.addEventListener('play', () => { P.audio.playbackRate = P.rate; });
['timeupdate', 'play', 'pause'].forEach(n => P.audio.addEventListener(n, paintPlayer));
P.audio.addEventListener('ended', () => { P.audio.currentTime = 0; paintPlayer(); });
async function togglePlay(room, ev){
  const id = ev.getId();
  if (P.id === id && !P.loading) { if (P.audio.paused) P.audio.play().catch(() => {}); else P.audio.pause(); return; }
  const c = ev.getContent();
  P.audio.pause(); P.id = id; P.loading = true; paintPlayer();
  try {
    const u = c.file ? await fetchEncrypted(c.file, c.info?.mimetype) : await fetchMedia(c.url, null);
    if (P.id !== id) return;
    P.audio.src = u;
    await P.audio.play();
  } catch (e) { toast('Не удалось воспроизвести: ' + e.message); P.id = null; }
  P.loading = false; paintPlayer();
}
function playerFrac(dur){
  if (!P.id) return 0;
  const d = isFinite(P.audio.duration) && P.audio.duration > 0 ? P.audio.duration * 1000 : dur;
  return d ? Math.min(1, P.audio.currentTime * 1000 / d) : 0;
}
function paintPlayer(){
  document.querySelectorAll('.voice').forEach(el => {
    const on = el.dataset.voice === P.id, dur = +el.dataset.dur || 0;
    const playing = on && !P.audio.paused;
    el.querySelector('.vplay').innerHTML = on && P.loading ? I.clock : playing ? I.pause : I.play;
    const bars = el.querySelectorAll('.vwave i'), n = on ? Math.round(playerFrac(dur) * bars.length) : 0;
    bars.forEach((b, i) => b.classList.toggle('done', i < n));
    const t = el.querySelector('.vtime');
    if (t.firstChild) t.firstChild.textContent = on && (playing || P.audio.currentTime > 0) ? fmtDur(P.audio.currentTime * 1000) : fmtDur(dur);
  });
}
function seekVoice(el, x){
  if (el.dataset.voice !== P.id) return;
  const w = el.querySelector('.vwave').getBoundingClientRect();
  const frac = Math.min(1, Math.max(0, (x - w.left) / w.width));
  const d = isFinite(P.audio.duration) && P.audio.duration > 0 ? P.audio.duration : (+el.dataset.dur || 0) / 1000;
  if (d) P.audio.currentTime = frac * d;
}

/* ---------- downloads ---------- */
const IS_ELECTRON = /Electron/.test(navigator.userAgent);
const safeName = n => String(n || 'file').replace(/[\/\\:*?"<>|\u0000-\u001f]+/g, '_').trim() || 'file';
const EXT = {'image/png':'png', 'image/jpeg':'jpg', 'image/gif':'gif', 'image/webp':'webp', 'audio/ogg':'ogg', 'audio/webm':'webm', 'audio/mp4':'m4a', 'video/mp4':'mp4', 'video/webm':'webm'};
function sendTyping(on){
  const room = cur(); if (!canSend(room)) return;
  const now = Date.now();
  if (on && now - S.typingSent < 4000) return;
  if (!on && !S.typingSent) return;
  S.typingSent = on ? now : 0;
  S.client.sendTyping(room.roomId, on, 6000).catch(() => {});
}
async function toggleReaction(room, targetId, key){
  const rel = room.relations?.getChildEventsForEvent(targetId, 'm.annotation', 'm.reaction');
  const set = rel?.getSortedAnnotationsByKey?.()?.find(([k]) => k === key)?.[1];
  const mine = set && [...set].find(e => e.getSender() === S.userId && !e.isRedacted());
  try {
    if (mine) { if (pendingStatus(mine)) return; await S.client.redactEvent(room.roomId, mine.getId()); }
    else await S.client.sendEvent(room.roomId, 'm.reaction', {'m.relates_to':{rel_type:'m.annotation', event_id:targetId, key}});
  } catch (e) { toast('Не удалось: ' + e.message); }
}
async function deleteMessage(room, id){
  const ok = await modal({title:'Удалить сообщение?', html:'<p>Сообщение будет удалено у всех участников чата.</p>', buttons:[{label:'Отмена'}, {label:'Удалить', value:true, danger:true}]});
  if (!ok) return;
  try { await S.client.redactEvent(room.roomId, id); } catch (e) { toast('Не удалось удалить: ' + e.message); }
}
async function downloadEvent(ev){
  const c = ev.getContent();
  const mxc = c.file?.url || c.url;
  if (!mxc) return;
  let name = safeName(c.filename || c.body || 'file');
  const ext = EXT[(c.info?.mimetype || '').split(';')[0]];
  if (ext && !/\.[a-z0-9]{2,5}$/i.test(name)) name += '.' + ext;
  const key = c.file ? c.file.url + '|enc' : c.url + '|full';
  try {
    let u = mediaReady.get(key);
    if (!u) {
      const r = await rawDownload(mxc, null);
      const total = +r.headers.get('content-length') || c.info?.size || 0;
      const chunks = []; let got = 0, last = 0;
      const reader = r.body.getReader();
      toast(`Скачивание «${name}»…`, true);
      for (;;) {
        const {done, value} = await reader.read();
        if (done) break;
        chunks.push(value); got += value.length;
        if (total && Date.now() - last > 200) { last = Date.now(); toast(`Скачивание «${name}» — ${Math.min(100, Math.round(got * 100 / total))}%`, true); }
      }
      let blob = new Blob(chunks);
      if (c.file) blob = new Blob([await decryptAttachment(await blob.arrayBuffer(), c.file)], {type:safeMime(c.info?.mimetype)});
      u = URL.createObjectURL(blob);
      mediaReady.set(key, u);
    }
    const a = document.createElement('a'); a.href = u; a.download = name; document.body.appendChild(a); a.click(); a.remove();
    toast(IS_ELECTRON ? `«${name}» сохранён в папку «Загрузки»` : `«${name}» скачан`);
  } catch (e) { toast('Не удалось скачать: ' + e.message); }
}

/* ---------- media viewer (photo / video), как в Telegram ---------- */
const V = {roomId:null, id:null};
const viewable = ev => !ev.isRedacted() && ev.getType() === 'm.room.message' && ['m.image', 'm.video'].includes(ev.getContent()?.msgtype) && (ev.getContent().url || ev.getContent().file);
function viewerList(room){ return liveEvents(room).filter(viewable); }
function closeViewer(){
  const lb = $('#lightbox');
  lb.querySelector('video')?.pause();
  lb.hidden = true; lb.innerHTML = ''; V.id = null;
}
async function openViewer(room, ev){
  V.roomId = room.roomId; V.id = ev.getId();
  const c = ev.getContent(), isVid = c.msgtype === 'm.video';
  const list = viewerList(room), i = list.findIndex(x => x.getId() === V.id);
  const thumb = !isVid && (c.file ? mediaReady.get(c.file.url + '|enc') : c.url && (mediaReady.get(c.url + '|full') || mediaReady.get(c.url + '|800')));
  const who = memberName(room, ev.getSender());
  const lb = $('#lightbox');
  lb.innerHTML = `<div class="lb-top">
      <div class="lb-who">${avatarHTML(room.getMember(ev.getSender())?.getMxcAvatarUrl() || '', ev.getSender(), who, 40)}<div><b>${esc(who)}</b><small>${esc(fmtDay(ev.getTs()))} в ${esc(fmtTime(ev.getTs()))}${list.length > 1 && i >= 0 ? ` · ${i + 1} из ${list.length}` : ''}</small></div></div>
      <div class="lb-acts">
        <button data-lb="download" title="Скачать">${I.download}</button>
        ${canSend(room) ? `<button data-lb="reply" title="Ответить">${I.reply}</button>` : ''}
        <button data-lb="forward" title="Переслать">${I.forward}</button>
        <button data-lb="more" title="Ещё">${I.dots}</button>
        <button data-lb="close" title="Закрыть (Esc)">${I.close}</button>
      </div></div>
    ${i > 0 ? `<button class="lb-nav prev" data-lb="prev" aria-label="Предыдущее">‹</button>` : ''}
    ${i >= 0 && i < list.length - 1 ? `<button class="lb-nav next" data-lb="next" aria-label="Следующее">›</button>` : ''}
    <div class="lb-stage">${isVid ? '<div class="loader" style="color:#fff">Загрузка видео…</div>' : `<img class="lb-media" alt=""${thumb ? ` src="${thumb}"` : ''}>`}</div>
    ${c.body && c.filename && c.body !== c.filename ? `<div class="lb-cap">${linkify(esc(c.body))}</div>` : ''}`;
  lb.hidden = false;
  hydrate(lb);
  try {
    const u = c.file ? await fetchEncrypted(c.file, c.info?.mimetype) : await fetchMedia(c.url, null);
    if (V.id !== ev.getId() || lb.hidden) return;
    if (isVid) { lb.querySelector('.lb-stage').innerHTML = '<video class="lb-media" controls autoplay playsinline></video>'; lb.querySelector('video').src = u; }
    else lb.querySelector('img').src = u;
  } catch (e) { if (V.id === ev.getId()) toast('Не удалось открыть: ' + e.message); }
}
function viewerStep(d){
  const room = S.client.getRoom(V.roomId); if (!room || !V.id) return;
  const list = viewerList(room), i = list.findIndex(x => x.getId() === V.id);
  const n = list[i + d]; if (n) openViewer(room, n);
}
const openVideo = ev => { const room = cur(); if (room) openViewer(room, ev); };
$('#lightbox').addEventListener('click', e => {
  const b = e.target.closest('[data-lb]');
  const room = S.client.getRoom(V.roomId), ev = room?.findEventById(V.id);
  if (!b) { if (!e.target.closest('.lb-media, .lb-top, .lb-cap')) closeViewer(); return; }
  e.stopPropagation();
  const a = b.dataset.lb;
  if (a === 'close') return closeViewer();
  if (a === 'prev') return viewerStep(-1);
  if (a === 'next') return viewerStep(1);
  if (!ev) return;
  if (a === 'download') downloadEvent(ev);
  else if (a === 'forward') { closeViewer(); forwardDialog(room, ev); }
  else if (a === 'reply') { closeViewer(); startReply(ev.getId()); }
  else if (a === 'more') { const r = b.getBoundingClientRect(); openCtx(r.left - 180, r.bottom + 6, ev.getId(), true); }
});

/* ---------- ссылки: клик — открыть, правый клик или удержание — меню ---------- */
function openLinkCtx(x, y, url){
  const m = $('#ctx');
  m.innerHTML = `<div class="ctx-link">${esc(url.length > 60 ? url.slice(0, 57) + '…' : url)}</div>
    <button class="mi" data-l="open">${I.join}Открыть ссылку</button>
    <button class="mi" data-l="copy">${I.copy}Копировать ссылку</button>
    <button class="mi" data-l="forward">${I.forward}Переслать ссылку</button>`;
  m.dataset.url = url; m.dataset.id = '';
  m.hidden = false;
  const w = m.offsetWidth, h = m.offsetHeight;
  m.style.left = Math.max(8, Math.min(x, innerWidth - w - 8)) + 'px';
  m.style.top = Math.max(8, Math.min(y, innerHeight - h - 8)) + 'px';
}
function openUrl(url){ if (/^https?:\/\//i.test(url)) window.open(url, '_blank', 'noopener,noreferrer'); }
// ---------- проверка ссылок перед открытием ----------
const KNOWN_DOMAINS = ['sberbank.ru','sber.ru','online.sberbank.ru','gosuslugi.ru','nalog.gov.ru','mos.ru','tbank.ru','tinkoff.ru','vtb.ru','alfabank.ru','gazprombank.ru','raiffeisen.ru','pochtabank.ru','yandex.ru','ya.ru','mail.ru','vk.com','ok.ru','ozon.ru','wildberries.ru','avito.ru','google.com','gmail.com','apple.com','icloud.com','microsoft.com','live.com','office.com','github.com','telegram.org','whatsapp.com','paypal.com','amazon.com','1c.ru','kontur.ru','hh.ru'];
const HOMO = {'а':'a','е':'e','о':'o','р':'p','с':'c','у':'y','х':'x','к':'k','м':'m','т':'t','в':'b','н':'h','і':'i','ј':'j','ѕ':'s','ԁ':'d','ӏ':'l','ɡ':'g','0':'o','1':'l'};
const skeleton = d => [...d.toLowerCase()].map(ch => HOMO[ch] || ch).join('').replace(/rn/g, 'm');
function lev(a, b){ if (Math.abs(a.length - b.length) > 2) return 9; const d = Array.from({length:a.length + 1}, (_, i) => [i]); for (let j = 1; j <= b.length; j++) d[0][j] = j; for (let i = 1; i <= a.length; i++) for (let j = 1; j <= b.length; j++) d[i][j] = Math.min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (a[i-1] === b[j-1] ? 0 : 1)); return d[a.length][b.length]; }
function linkRisks(url, shown){
  const out = [];
  let u; try { u = new URL(url); } catch { return ['Некорректная ссылка']; }
  if (!/^https?:$/.test(u.protocol)) return ['Ссылка ведёт не на сайт (' + u.protocol + ')'];
  // настоящее имя сайта в Юникоде (браузер хранит его в punycode)
  let host = u.hostname;
  const shownHost = (() => { try { return new URL(shown).hostname; } catch { return ''; } })();
  const uni = /[^\x00-\x7f]/.test(shown || '') ? (/^https?:\/\/([^/?#:]+)/i.exec(shown)?.[1] || host) : host;
  const own = S.userId ? serverName() : '';
  if (shown && /^https?:\/\//i.test(shown) && shownHost && shownHost !== host && !/[^\x00-\x7f]/.test(shownHost)) out.push(`Текст ссылки показывает «${shownHost}», а на самом деле она ведёт на «${host}»`);
  if (/(^|\.)xn--/.test(host) || /[^\x00-\x7f]/.test(uni)) {
    const labels = uni.split('.');
    if (labels.some(l => /[a-z]/i.test(l) && /[Ѐ-ӿ]/.test(l))) out.push(`В адресе «${uni}» смешаны латинские и русские буквы — так маскируют поддельные сайты`);
    else out.push(`Адрес «${uni}» записан нестандартными символами`);
  }
  if (u.username || u.password) out.push(`Перед «@» в адресе стоит «${u.username}» — на самом деле ссылка ведёт на «${host}»`);
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.startsWith('[')) out.push('Ссылка ведёт на IP-адрес, а не на имя сайта');
  const list = [...KNOWN_DOMAINS, own].filter(Boolean);
  if (!list.some(k => host === k || host.endsWith('.' + k))) {
    const sk = skeleton(uni.replace(/^www\./, '')), reg = sk.split('.').slice(-2).join('.');
    const hit = list.find(k => sk === k || sk.endsWith('.' + k) || reg === k || (reg.length > 5 && lev(reg, k) === 1));
    if (hit) out.push(`Адрес «${uni}» очень похож на «${hit}», но это другой сайт`);
  }
  if (u.protocol === 'http:' && !out.length) {} // обычный http не пугаем, Element тоже не пугает
  return out;
}
async function safeOpen(url, shown){
  const r = linkRisks(url, shown);
  if (!r.length) return openUrl(url);
  const ok = await modal({title:'Подозрительная ссылка', html:`<p>⚠️ Будьте осторожны: так выглядят фишинговые ссылки, которые крадут пароли и деньги.</p><ul class="risk">${r.map(x => `<li>${esc(x)}</li>`).join('')}</ul><p class="lk"><code>${esc(url)}</code></p>`, buttons:[{label:'Не открывать'}, {label:'Открыть всё равно', value:true, danger:true}]});
  if (ok) openUrl(url);
}
document.addEventListener('click', e => {
  const a = e.target.closest('a[href]'); if (!a || e.defaultPrevented) return;
  if (!/^https?:/i.test(a.getAttribute('href') || '')) return;
  if (linkHeld) return;
  e.preventDefault(); e.stopPropagation();
  safeOpen(a.href, a.textContent.trim());
}, true);
let linkHoldT = null, linkHeld = false;
function linkHold(e, x, y){
  const a = e.target.closest('a[href]'); if (!a) return;
  linkHeld = false; clearTimeout(linkHoldT);
  linkHoldT = setTimeout(() => { linkHeld = true; navigator.vibrate?.(10); openLinkCtx(x, y, a.href); }, 500);
}
const linkCancel = () => clearTimeout(linkHoldT);

/* ---------- composer bar ---------- */
function renderBar(){
  const bar = $('#bar'), room = cur();
  const id = S.editing || S.reply;
  if (!room || !id) { bar.hidden = true; bar.innerHTML = ''; return; }
  const ev = room.findEventById(id);
  const title = S.editing ? 'Редактирование' : 'В ответ ' + (ev ? memberName(room, ev.getSender()) : '');
  bar.innerHTML = `<div class="bq"><b>${esc(title)}</b><span>${esc(ev ? snippet(room, ev) : '')}</span></div><button class="icon-btn" data-act="cancel-bar" aria-label="Отменить">${I.close}</button>`;
  bar.hidden = false;
}
function startReply(id){ S.editing = null; S.reply = id; renderBar(); $('#input').focus(); }
function startEdit(id){
  const room = cur(), ev = room?.findEventById(id); if (!ev) return;
  S.reply = null; S.editing = id;
  $('#input').value = stripReply(ev.getContent().body); autosize(); renderBar(); updateSendBtn();
  const inp = $('#input'); inp.focus(); inp.setSelectionRange(inp.value.length, inp.value.length);
}
function cancelBar(){ if (S.editing) { $('#input').value = ''; autosize(); } S.reply = null; S.editing = null; renderBar(); updateSendBtn(); }
function autosize(){ const t = $('#input'); t.style.height = 'auto'; t.style.height = Math.min(t.scrollHeight, 200) + 'px'; }

/* ---------- context menu ---------- */
function openCtx(x, y, id, fromViewer){
  const room = cur(), ev = room?.findEventById(id); if (!ev || !isMsg(ev)) return;
  const mine = ev.getSender() === S.userId, redacted = ev.isRedacted(), st = pendingStatus(ev);
  const c = ev.getContent() || {};
  const ok = canSend(room) && !redacted && !st && !ev.isDecryptionFailure();
  const hasMedia = !redacted && !!(c.url || c.file?.url);
  let h = ok ? `<div class="ctx-r">${REACTIONS.map(r => `<button data-r="${r}">${r}</button>`).join('')}<button class="more" data-a="react-more" title="Другие эмодзи">＋</button></div>` : '';
  if (st === 'not_sent') h += `<button class="mi" data-a="retry">${I.retry}Отправить ещё раз</button>`;
  if (ok) h += `<button class="mi" data-a="reply">${I.reply}Ответить</button>`;
  if (!redacted && !st && !ev.isDecryptionFailure() && ev.getType() !== 'm.room.encrypted') h += `<button class="mi" data-a="forward">${I.forward}Переслать</button>`;
  if (!redacted && !st && canPin(room)) h += `<button class="mi" data-a="pin">${I.pin}${pinnedIds(room).includes(id) ? 'Открепить' : 'Закрепить'}</button>`;
  if (!redacted && c.body && ev.getType() === 'm.room.message' && ['m.text', 'm.notice', 'm.emote'].includes(c.msgtype)) h += `<button class="mi" data-a="copy">${I.copy}Копировать текст</button>`;
  if (hasMedia) h += `<button class="mi" data-a="download">${I.download}Скачать</button>`;
  if (hasMedia && (ev.getType() === 'm.sticker' || c.msgtype === 'm.image')) h += `<button class="mi" data-a="sticker">${I.sticker}В мои стикеры</button>`;
  if (mine && ok && (c.msgtype === 'm.text' || c.msgtype === 'm.emote')) h += `<button class="mi" data-a="edit">${I.edit}Изменить</button>`;
  if (!st && (ev.isEncrypted() || isEncrypted(room))) h += `<button class="mi" data-a="crypto">${I.shield}Шифрование сообщения</button>`;
  if (mine && !redacted && !st) h += `<button class="mi danger" data-a="delete">${I.trash}Удалить</button>`;
  if (st === 'not_sent') h += `<button class="mi danger" data-a="discard">${I.trash}Убрать</button>`;
  if (!h) return;
  const m = $('#ctx'); m.innerHTML = h; m.hidden = false; m.dataset.id = id; m.dataset.url = '';
  m.classList.toggle('over', !!fromViewer);
  const w = m.offsetWidth, hh = m.offsetHeight;
  m.style.left = Math.max(8, Math.min(x, innerWidth - w - 8)) + 'px';
  m.style.top = Math.max(8, Math.min(y, innerHeight - hh - 8)) + 'px';
}
function closeCtx(){ $('#ctx').hidden = true; }
$('#ctx').addEventListener('click', e => {
  const lk = e.target.closest('[data-l]');
  if (lk) {
    e.stopPropagation();
    const url = $('#ctx').dataset.url; closeCtx();
    if (lk.dataset.l === 'open') safeOpen(url);
    else if (lk.dataset.l === 'copy') navigator.clipboard?.writeText(url).then(() => toast('Ссылка скопирована'), () => toast('Не удалось скопировать'));
    else if (lk.dataset.l === 'forward') { const room = cur(); if (room) forwardDialog(room, null, {type:'m.room.message', content:{msgtype:'m.text', body:url}}); }
    return;
  }
  const room = cur(), id = $('#ctx').dataset.id, ev = room?.findEventById(id);
  const rb = e.target.closest('[data-r]'), ab = e.target.closest('[data-a]');
  e.stopPropagation();
  closeCtx();
  if (!ev) return;
  if (!$('#lightbox').hidden && !rb && ab && !['download', 'copy', 'sticker'].includes(ab.dataset.a)) closeViewer();
  if (rb) return toggleReaction(room, id, rb.dataset.r);
  if (!ab) return;
  const a = ab.dataset.a;
  if (a === 'reply') startReply(id);
  else if (a === 'react-more') openPicker('react', id);
  else if (a === 'forward') forwardDialog(room, ev);
  else if (a === 'pin') togglePin(room, id);
  else if (a === 'copy') navigator.clipboard?.writeText(stripReply(ev.getContent().body)).then(() => toast('Текст скопирован'), () => toast('Не удалось скопировать'));
  else if (a === 'download') downloadEvent(ev);
  else if (a === 'sticker') saveAsSticker(room, ev);
  else if (a === 'edit') startEdit(id);
  else if (a === 'crypto') showEventCrypto(room, ev);
  else if (a === 'delete') deleteMessage(room, id);
  else if (a === 'retry') S.client.resendEvent(ev, room).catch(err => toast('Не отправлено: ' + err.message));
  else if (a === 'discard') { S.client.cancelPendingEvent(ev); schedule(); }
});
async function showEventCrypto(room, ev){
  const w = ev.getWireContent() || {};
  const encd = ev.isEncrypted();
  let info = null;
  if (encd && !ev.isDecryptionFailure()) { try { info = await crypto_()?.getEncryptionInfoForEvent(ev); } catch {} }
  const row = (k, v) => `<div class="info-row"><small>${esc(k)}</small>${v}</div>`;
  const ct = String(w.ciphertext || '');
  const html = encd ? [
    row('Статус', ev.isDecryptionFailure() ? '🔒 Зашифровано, но ключа для расшифровки на этом устройстве нет' : '✅ Зашифровано сквозным шифрованием. Сервер хранит только шифротекст.'),
    row('Алгоритм', `<code>${esc(w.algorithm || '—')}</code>`),
    row('Проверка отправителя', esc(info ? shieldReasonText(info) : ev.isDecryptionFailure() ? 'Невозможно без ключа' : 'Нет данных')),
    row('Устройство отправителя', `<code>${esc(w.device_id || '—')}</code>`),
    row('Сессия Megolm', `<code>${esc(w.session_id || '—')}</code>`),
    row('Так сообщение лежит на сервере', `<code>${esc(ct.slice(0, 180))}${ct.length > 180 ? '…' : ''}</code>`),
  ].join('') : row('Статус', '⚠️ Это сообщение отправлено без шифрования — администратор сервера может прочитать его текст.');
  modal({title:'Шифрование сообщения', html, buttons:[{label:'Закрыть', value:true}]});
}
/* ---------- dialogs ---------- */
// ---------- значки в стиле приложения (линейные, в цветных плашках как в Telegram/iOS) ----------
const SVGI = {
  bell:'<path d="M6 8a6 6 0 0112 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 003.4 0"/>',
  msg:'<path d="M21 15a2 2 0 01-2 2H7l-4 4V5a2 2 0 012-2h14a2 2 0 012 2z"/>',
  sound:'<path d="M11 5L6 9H2v6h4l5 4z"/><path d="M15.5 8.5a5 5 0 010 7M19 5a10 10 0 010 14"/>',
  check:'<path d="M20 6L9 17l-5-5"/>',
  moon:'<path d="M21 12.8A9 9 0 1111.2 3a7 7 0 009.8 9.8z"/>',
  palette:'<path d="M12 22a10 10 0 110-20c5.5 0 10 4 10 8.5 0 2.5-2 4.5-4.5 4.5H15a2 2 0 00-1.5 3.3A2 2 0 0112 22z"/><circle cx="7.5" cy="10.5" r="1"/><circle cx="12" cy="7" r="1"/><circle cx="16.5" cy="10.5" r="1"/>',
  image:'<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 15l-5-5L5 21"/>',
  text:'<path d="M4 7V4h16v3M9 20h6M12 4v16"/>',
  rows:'<path d="M3 6h18M3 12h18M3 18h18"/>',
  lock:'<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 018 0v4"/>',
  shield:'<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="M9 12l2 2 4-4"/>',
  key:'<circle cx="7.5" cy="15.5" r="4.5"/><path d="M10.7 12.3L21 2M16 7l3 3M19 4l2 2"/>',
  monitor:'<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>',
  phone:'<path d="M6.6 10.8a15.1 15.1 0 006.6 6.6l2.2-2.2a1 1 0 011-.25 11.4 11.4 0 003.6.57 1 1 0 011 1V20a1 1 0 01-1 1A17 17 0 013 4a1 1 0 011-1h3.5a1 1 0 011 1c0 1.25.2 2.45.57 3.6a1 1 0 01-.25 1z"/>',
  user:'<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0116 0"/>',
  logout:'<path d="M9 21H5a2 2 0 01-2-2V5a2 2 0 012-2h4M16 17l5-5-5-5M21 12H9"/>',
  info:'<circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/>',
  trash:'<path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6"/>',
  edit:'<path d="M12 20h9M16.5 3.5a2.1 2.1 0 013 3L7 19l-4 1 1-4z"/>',
  camera:'<path d="M23 19a2 2 0 01-2 2H3a2 2 0 01-2-2V8a2 2 0 012-2h4l2-3h6l2 3h4a2 2 0 012 2z"/><circle cx="12" cy="13" r="4"/>',
  upload:'<path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M17 8l-5-5-5 5M12 3v12"/>',
  download:'<path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M7 10l5 5 5-5M12 15V3"/>',
  copy:'<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/>',
  useradd:'<circle cx="9" cy="8" r="4"/><path d="M2 21a7 7 0 0114 0M19 8v6M22 11h-6"/>',
  users:'<circle cx="9" cy="8" r="4"/><path d="M2 21a7 7 0 0114 0"/><path d="M16 3.1a4 4 0 010 7.8M22 21a7 7 0 00-4-6.3"/>',
  timer:'<circle cx="12" cy="13" r="8"/><path d="M12 9v4l2 2M9 2h6"/>',
  refresh:'<path d="M3 12a9 9 0 0115-6.7L21 8M21 3v5h-5M21 12a9 9 0 01-15 6.7L3 16M3 21v-5h5"/>',
  sliders:'<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/>',
  grid:'<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/>',
  link:'<path d="M10 13a5 5 0 007.5.5l3-3a5 5 0 00-7-7l-1.7 1.7M14 11a5 5 0 00-7.5-.5l-3 3a5 5 0 007 7l1.7-1.7"/>',
  search:'<circle cx="11" cy="11" r="7"/><path d="M21 21l-4.3-4.3"/>',
  chat:'<path d="M21 11.5a8.4 8.4 0 01-9 8.4 8.6 8.6 0 01-4-1L3 20l1.2-4.4A8.4 8.4 0 1121 11.5z"/>',
  mute:'<path d="M11 5L6 9H2v6h4l5 4z"/><path d="M23 9l-6 6M17 9l6 6"/>',
  pin:'<path d="M12 17v5M9 10.8V4h6v6.8l3 3.2v2H6v-2z"/>',
  dot:'<circle cx="12" cy="12" r="3"/>',
};
const I_ = n => `<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${SVGI[n]}</svg>`;
const ico = (name, color) => `<span class="sti" style="--ic:${color}"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${SVGI[name] || SVGI.dot}</svg></span>`;
const ROW_IC = [[/удалить|завершить|выйти|покинуть|отклонить|отключить|сбросить/i, 'trash', '#ff453a'], [/медиа|файл/i, 'grid', '#0a84ff'], [/ссылк|адрес/i, 'link', '#5e5ce6'], [/фото/i, 'camera', '#30b0c7'], [/имя|переименовать|название/i, 'edit', '#ff9f0a'], [/пароль|код/i, 'lock', '#8e8e93'], [/сеанс/i, 'monitor', '#0a84ff'], [/экспорт|сохранить ключ/i, 'upload', '#32d74b'], [/импорт/i, 'download', '#32d74b'], [/ключ/i, 'key', '#ff9f0a'], [/провер|подтверд/i, 'shield', '#32d74b'], [/копи/i, 'copy', '#64d2ff'], [/пригласить/i, 'useradd', '#0a84ff'], [/автоудал|автоблок/i, 'timer', '#ff9f0a'], [/шифров/i, 'lock', '#5e5ce6'], [/настро/i, 'sliders', '#8e8e93'], [/уведомл/i, 'bell', '#ff453a'], [/звук/i, 'sound', '#ff375f'], [/текст/i, 'msg', '#0a84ff'], [/восстанов/i, 'refresh', '#32d74b'], [/звон/i, 'phone', '#32d74b'], [/скорост|изменить/i, 'edit', '#ff9f0a']];
const rowIcon = t => { const m = ROW_IC.find(([re]) => re.test(t)); return m ? ico(m[1], m[2]) : ico('dot', '#8e8e93'); };
const isCloser = b => (b.value === undefined || b.value === null) && /^(Закрыть|Отмена|Готово|Понятно|Нет)$/i.test(b.label);
const dlgHead = (title, attr) => `<div class="up-head"><button class="up-back" ${attr} aria-label="Назад">${I.back}</button><h3>${esc(title)}</h3></div>`;
function modal({title, html = '', input = null, inputType = 'text', value = '', buttons}){
  buttons = buttons || [{label:'Отмена'}, {label:'OK', value:true}];
  return new Promise(res => {
    const m = $('#modal');
    const back = S.settingsNav;
    const acts = buttons.filter(b => !isCloser(b));
    const asRows = !input && acts.length >= 2;
    const btnHTML = asRows
      ? `<div class="st-list">${buttons.map((b, i) => isCloser(b) ? '' : `<button class="st-row${b.danger ? ' danger' : ''}" data-i="${i}"><span class="st-ic">${rowIcon(b.label)}</span><span class="st-t"><span>${esc(b.label)}</span></span><span class="st-r">${b.danger ? '' : I.chevR}</span></button>`).join('')}</div>`
      : `<div class="dlg-btns">${buttons.map((b, i) => `<button class="btn-flat${b.danger ? ' danger' : ''}" data-i="${i}">${esc(b.label)}</button>`).join('')}</div>`;
    m.innerHTML = `<div class="dlg${asRows ? ' st-dlg' : ''}" role="dialog" aria-modal="true" aria-label="${esc(title)}">${dlgHead(title, 'data-back')}${asRows && html ? `<div class="st-body">${html}</div>` : html}${input ? `<input class="field" id="m-in" type="${inputType}" placeholder="${esc(input)}" value="${esc(value)}" autocomplete="off" autocapitalize="off" spellcheck="false">` : ''}${btnHTML}</div>`;
    m.hidden = false;
    const inp = m.querySelector('#m-in');
    (inp || m.querySelector(asRows ? '.st-row' : `[data-i="${buttons.length - 1}"]`))?.focus();
    const done = v => { m.hidden = true; m.innerHTML = ''; m.onclick = null; document.removeEventListener('keydown', key, true); res(v); };
    const val = b => b.value === true && inp ? inp.value.trim() || null : b.value ?? null;
    const key = e => {
      if (e.key === 'Escape') { e.stopPropagation(); done(null); }
      else if (e.key === 'Enter' && inp && document.activeElement === inp) { e.preventDefault(); done(val(buttons[buttons.length - 1])); }
    };
    document.addEventListener('keydown', key, true);
    m.onclick = e => {
      if (e.target === m) return done(null);
      if (e.target.closest('[data-back]')) { done(null); if (back) setTimeout(settingsDialog, 0); return; }
      const b = e.target.closest('[data-i]'); if (b) done(val(buttons[+b.dataset.i]));
    };
  });
}
let panelHandler = null;
// opts.back — заголовок со стрелкой «назад» (закрывает окно)
function panel(html, handler, opts = {}){
  const m = $('#modal');
  if (opts.back) html = html.replace(/^\s*<h3>(.*?)<\/h3>/s, (_, t) => `<div class="up-head"><button class="up-back" data-pback aria-label="Назад">${I.back}</button><h3>${t}</h3></div>`);
  m.innerHTML = `<div class="dlg${opts.cls ? ' ' + opts.cls : ''}" role="dialog" aria-modal="true">${html}</div>`;
  m.hidden = false; panelHandler = handler;
  const back = S.settingsNav;
  m.onclick = e => {
    if (e.target.closest('[data-pback]')) { closePanel(); if (back) setTimeout(settingsDialog, 0); return; }
    const b = e.target.closest('[data-v]'); if (b && panelHandler) panelHandler(b.dataset.v);
  };
}
function closePanel(){ const m = $('#modal'); m.hidden = true; m.innerHTML = ''; m.onclick = null; panelHandler = null; }

/* ---------- encryption: secret storage, recovery, verification ---------- */
let ssCache = null, pendingKeyInput = null;
const cryptoCallbacks = {
  getSecretStorageKey: async ({keys}) => {
    const ids = Object.keys(keys || {});
    if (ssCache && keys[ssCache.keyId]) return [ssCache.keyId, ssCache.key];
    if (pendingKeyInput == null) throw new Error('Нужен ключ восстановления');
    const def = await S.client.secretStorage.getDefaultKeyId().catch(() => null);
    const keyId = def && keys[def] ? def : ids[0];
    const info = keys[keyId];
    const raw = pendingKeyInput.trim();
    let key = null;
    try { key = CA.decodeRecoveryKey(raw); } catch {}
    if (!key && info?.passphrase && CA.deriveRecoveryKeyFromPassphrase) {
      key = await CA.deriveRecoveryKeyFromPassphrase(raw, info.passphrase.salt, info.passphrase.iterations, info.passphrase.bits || 256);
    }
    if (!key || !(await S.client.secretStorage.checkKey(key, info))) throw new Error('Ключ восстановления не подходит');
    ssCache = {keyId, key};
    return [keyId, key];
  },
  cacheSecretStorageKey: (keyId, _info, key) => { ssCache = {keyId, key}; },
};
async function refreshCryptoState(){
  shields.clear();
  const c = crypto_();
  if (!c) { S.cstate = {ready:false, hasCS:false, verified:false}; renderBanner(); return; }
  try {
    const st = await c.getDeviceVerificationStatus(S.userId, S.deviceId);
    const verified = !!st?.crossSigningVerified;
    const hasCS = verified || await c.userHasCrossSigningKeys(S.userId, true);
    S.cstate = {ready:true, hasCS, verified};
  } catch (e) { console.warn(e); S.cstate = {ready:true, hasCS:true, verified:false}; }
  renderBanner();
  schedule();
  if (S.cstate.verified && S.initialDone) setTimeout(autoKeySync, 1500);
}
// Как в Element: без подтверждения новый вход дальше не пускаем (только подтвердить, сбросить или выйти)
function renderGate(){
  const st = S.cstate || {}, g = $('#vgate');
  const need = S.initialDone && st.ready && st.hasCS && !st.verified;
  g.hidden = !need;
  document.body.classList.toggle('gated', need);
}
$('#vgate').addEventListener('click', async e => {
  const b = e.target.closest('[data-g]'); if (!b) return;
  const a = b.dataset.g;
  if (a === 'key') recoveryKeyFlow();
  else if (a === 'device') requestDeviceVerification();
  else if (a === 'logout') doLogout();
  else if (a === 'reset') {
    const ok = await modal({title:'Сбросить ключи шифрования?', html:'<p>Делайте это, только если у вас <b>нет</b> ни ключа восстановления, ни другого устройства со входом.</p><p>Будут созданы новые ключи. <b>Старые зашифрованные сообщения станут недоступны</b>, а у собеседников появится предупреждение, что ваши ключи сменились. Другие ваши устройства придётся подтвердить заново.</p>', buttons:[{label:'Отмена'}, {label:'Сбросить и создать новые', value:true, danger:true}]});
    if (ok) setupEncryption({reset:true});
  }
});
function renderBanner(){
  renderGate();
  const b = $('#cbanner'), st = S.cstate;
  if (!S.initialDone || !st.ready || st.verified) { b.hidden = true; return; }
  b.innerHTML = st.hasCS
    ? `<b>${I.lock}Подтвердите этот вход</b><span>Без этого старые зашифрованные сообщения не прочитать.</span><div class="acts"><button data-c="key">Ключ восстановления</button><button data-c="device">Другое устройство</button></div>`
    : `<b>${I.lock}Шифрование не настроено</b><span>Создайте ключ восстановления, чтобы не потерять доступ к переписке.</span><div class="acts"><button data-c="setup">Настроить</button></div>`;
  b.hidden = false;
}
async function recoveryKeyFlow(){
  const key = await modal({title:'Ключ восстановления', html:'<p>Введите ключ восстановления из Element (Security Key, 48 символов группами по 4). Если вы задавали секретную фразу, можно ввести её.</p>', input:'EsTc abcd 1234 …', buttons:[{label:'Отмена'}, {label:'Продолжить', value:true}]});
  if (!key) return;
  const c = crypto_(); if (!c) return;
  toast('Проверяем ключ…', true);
  pendingKeyInput = key; ssCache = null;
  try {
    await c.bootstrapCrossSigning({});
    // Явно подписываем это устройство ключом кросс-подписи — иначе оно может остаться «не подтверждённым».
    try { await c.crossSignDevice?.(S.deviceId); } catch (e) { console.warn('crossSignDevice', e); }
    await c.loadSessionBackupPrivateKeyFromSecretStorage?.();
    toast('Вход подтверждён');
    await refreshCryptoState();
    await restoreBackup();
  } catch (e) {
    console.error(e);
    toast('Не получилось: ' + (e.message || e));
  } finally { pendingKeyInput = null; }
}
// ---------- автоматическая подкачка ключей (чтобы не было «Не удалось расшифровать») ----------
// Как в Element: если этот вход подтверждён и на сервере есть резервная копия ключей,
// включаем её — тогда недостающие ключи для сообщений скачиваются сами, по мере надобности.
// Плюс один раз за сеанс тихо подтягиваем всю копию, если в чатах есть нерасшифрованные сообщения.
let keySyncDone = false, keySyncBusy = false;
async function autoKeySync(){
  const c = crypto_();
  if (!c || keySyncBusy || !S.cstate?.verified) return;
  keySyncBusy = true;
  try {
    const check = await c.checkKeyBackupAndEnable?.();
    if (!check?.backupInfo) return;
    let key = await c.getSessionBackupPrivateKey?.();
    if (!key) { try { await c.loadSessionBackupPrivateKeyFromSecretStorage?.(); key = await c.getSessionBackupPrivateKey?.(); } catch {} }
    if (!key || keySyncDone) return;
    const utd = S.client.getRooms().some(r => liveEvents(r).some(e => e.isDecryptionFailure?.()));
    if (!utd) { keySyncDone = true; return; }
    keySyncDone = true;
    const r = await c.restoreKeyBackup({});
    if (r?.imported) { toast(`Подтянуты ключи для старых сообщений: ${r.imported}`); schedule(); }
  } catch (e) { console.warn('autoKeySync', e); }
  finally { keySyncBusy = false; }
}
// повторная попытка при новых нерасшифрованных сообщениях (не чаще раза в 2 минуты)
let utdT = 0;
function onUTD(){
  if (Date.now() - utdT < 120e3) return;
  utdT = Date.now(); keySyncDone = false;
  setTimeout(autoKeySync, 3000);
}
async function restoreBackup(){
  const c = crypto_(); if (!c) return;
  try {
    const check = await c.checkKeyBackupAndEnable?.();
    if (check && !check.backupInfo) { toast('Резервной копии ключей на сервере нет'); return; }
    if (c.getSessionBackupPrivateKey && !(await c.getSessionBackupPrivateKey())) { toast('Ключ резервной копии не найден — введите ключ восстановления'); return; }
    if (!c.restoreKeyBackup) { toast('Эта версия matrix-js-sdk не умеет восстанавливать резервную копию'); return; }
    toast('Восстанавливаем ключи…', true);
    const r = await c.restoreKeyBackup({progressCallback:p => { if (p?.total) toast(`Восстанавливаем ключи… ${p.successes || 0} из ${p.total}`, true); }});
    toast(`Готово: восстановлено ключей — ${r?.imported ?? '?'} из ${r?.total ?? '?'}`);
    schedule();
  } catch (e) { console.error(e); toast('Не удалось восстановить ключи: ' + (e.message || e)); }
}
async function setupEncryption(opts = {}){
  const c = crypto_(); if (!c) return;
  const pw = await modal({title:opts.reset ? 'Новые ключи шифрования' : 'Настроить шифрование', html:'<p>Будет создан ключ восстановления — с ним вы сможете читать зашифрованную переписку на новых устройствах. Для подтверждения введите пароль от аккаунта.</p>', input:'Пароль', inputType:'password', buttons:[{label:'Отмена'}, {label:'Создать ключ', value:true}]});
  if (!pw) return;
  toast('Настраиваем шифрование…', true);
  try {
    await c.bootstrapCrossSigning({
      setupNewCrossSigning:!!opts.reset,
      authUploadDeviceSigningKeys: async makeRequest => {
        try { await makeRequest(null); }
        catch (e) {
          const session = e.data?.session;
          if (!session) throw e;
          await makeRequest({type:'m.login.password', identifier:{type:'m.id.user', user:S.userId}, password:pw, session});
        }
      },
    });
    const rk = await c.createRecoveryKeyFromPassphrase();
    await c.bootstrapSecretStorage({createSecretStorageKey:async () => rk, setupNewSecretStorage:true, setupNewKeyBackup:true});
    $('#toast').hidden = true;
    await refreshCryptoState();
    const v = await modal({title:'Сохраните ключ восстановления', html:`<p>Запишите ключ и храните в надёжном месте. Без него не получится прочитать старые сообщения на новом устройстве.</p><div class="rkey">${esc(rk.encodedPrivateKey)}</div>`, buttons:[{label:'Скопировать', value:'copy'}, {label:'Я сохранил(а)', value:true}]});
    if (v === 'copy') navigator.clipboard?.writeText(rk.encodedPrivateKey).then(() => toast('Ключ скопирован'));
  } catch (e) { console.error(e); toast('Не удалось настроить: ' + (e.message || e)); }
}
const PH = {READY:CA.VerificationPhase?.Ready ?? 3, STARTED:CA.VerificationPhase?.Started ?? 4, CANCELLED:CA.VerificationPhase?.Cancelled ?? 5, DONE:CA.VerificationPhase?.Done ?? 6};
const EV_CHANGE = CA.VerificationRequestEvent?.Change ?? 'change';
const EV_SAS = CA.VerifierEvent?.ShowSas ?? 'show_sas';
async function requestDeviceVerification(){
  const c = crypto_(); if (!c) return;
  try { verifyFlow(await c.requestOwnUserVerification()); }
  catch (e) { toast('Не удалось отправить запрос: ' + (e.message || e)); }
}
function verifyFlow(req){
  let verifierUsed = false, finished = false;
  const closeBtn = '<div class="dlg-btns"><button class="btn-flat" data-v="close">Закрыть</button></div>';
  const cancelBtn = '<div class="dlg-btns"><button class="btn-flat danger" data-v="cancel">Отменить</button></div>';
  const show = (html, btns = cancelBtn, handler) => panel(`<h3>Подтверждение</h3>${html}${btns}`, handler || (v => {
    if (v === 'cancel') { req.cancel?.().catch(() => {}); closePanel(); }
    if (v === 'close') closePanel();
  }));
  const showSas = sas => {
    const em = sas.sas?.emoji || [];
    show(`<p>Сравните эмодзи с другим устройством. Они должны совпадать и идти в том же порядке.</p><div class="sas">${em.map(([e, n]) => `<div><span>${e}</span><small>${esc(n)}</small></div>`).join('')}</div>`,
      '<div class="dlg-btns"><button class="btn-flat danger" data-v="no">Не совпадают</button><button class="btn-flat" data-v="yes">Совпадают</button></div>',
      v => {
        if (v === 'yes') { sas.confirm().catch(() => {}); show('<p>Ждём подтверждения на другом устройстве…</p>'); }
        if (v === 'no') { sas.mismatch(); closePanel(); toast('Подтверждение отменено'); }
      });
  };
  const useVerifier = verifier => {
    if (verifierUsed || !verifier) return;
    verifierUsed = true;
    verifier.on(EV_SAS, showSas);
    const now = verifier.getShowSasCallbacks?.(); if (now) showSas(now);
    verifier.verify().catch(e => { if (!finished) toast('Подтверждение не завершено: ' + (e.message || e)); });
  };
  const onChange = async () => {
    if (finished) return;
    if (req.phase === PH.READY && req.initiatedByMe && !verifierUsed) {
      show('<p>Устройство ответило, начинаем сравнение…</p>');
      try { useVerifier(await req.startVerification('m.sas.v1')); } catch (e) { toast('Ошибка: ' + (e.message || e)); }
    } else if (req.phase === PH.STARTED && req.verifier) {
      useVerifier(req.verifier);
    } else if (req.phase === PH.DONE) {
      finished = true; req.off?.(EV_CHANGE, onChange);
      const selfDone = req.isSelfVerification ?? req.otherUserId === S.userId;
      show(selfDone ? '<p>Готово, этот вход подтверждён. Ключи для старых сообщений сейчас подтянутся.</p>' : '<p>Готово, собеседник подтверждён. Если его ключи когда-нибудь сменятся, вы увидите предупреждение.</p>', closeBtn);
      await refreshCryptoState();
      if (selfDone) setTimeout(restoreBackup, 2500);
    } else if (req.phase === PH.CANCELLED) {
      finished = true; req.off?.(EV_CHANGE, onChange);
      show('<p>Подтверждение отменено.</p>', closeBtn);
    }
  };
  req.on(EV_CHANGE, onChange);
  const selfV = req.isSelfVerification ?? req.otherUserId === S.userId;
  show(req.initiatedByMe
    ? (selfV ? '<p>Откройте Element на устройстве, где вы уже вошли, и примите запрос на подтверждение. Затем сравните эмодзи.</p>' : '<p>Собеседнику отправлен запрос. Когда он примет его в своём приложении, сравните эмодзи — лучше голосом или при встрече.</p>')
    : '<p>Подключаемся…</p>');
  if (!req.initiatedByMe) req.accept().catch(e => toast('Ошибка: ' + (e.message || e)));
  onChange();
}
async function onIncomingVerification(req){
  if (req.phase === PH.CANCELLED || req.phase === PH.DONE) return;
  const self = req.isSelfVerification ?? req.otherUserId === S.userId;
  const ok = await modal({title:'Запрос на подтверждение', html:`<p>${self ? 'Другое ваше устройство' : esc(S.client.getUser(req.otherUserId)?.displayName || localpart(req.otherUserId))} хочет подтвердить этот вход сравнением эмодзи.</p>`, buttons:[{label:'Отклонить', value:'no'}, {label:'Принять', value:true}]});
  if (ok === true) verifyFlow(req); else req.cancel?.().catch(() => {});
}
// Защищённая рассылка ключей (по умолчанию включена): ключи от сообщений получают только устройства,
// которые их владелец подтвердил (подписал). Вошедший по украденному паролю без ключа восстановления
// и без подтверждения с другого устройства переписку не прочитает. Выключить можно в «Шифрование».
const LS_STRICT = 'mxtg.strict';
const strictOn = () => { try { return localStorage.getItem(LS_STRICT) !== '0'; } catch { return true; } };
function applyStrict(){
  const c = crypto_(); if (!c) return;
  try {
    c.globalBlacklistUnverifiedDevices = false;
    c.setDeviceIsolationMode?.(strictOn() ? new CA.OnlySignedDevicesIsolationMode() : new CA.AllDevicesIsolationMode(false));
  } catch (e) { console.warn('isolation mode', e); }
}
async function cryptoDialog(){
  await refreshCryptoState();
  const st = S.cstate, strict = strictOn();
  const status = !st.ready ? 'Шифрование не запустилось в этом браузере.'
    : !st.hasCS ? 'Шифрование для аккаунта ещё не настроено.'
    : st.verified ? 'Этот вход подтверждён ✓' : 'Этот вход не подтверждён — старые зашифрованные сообщения не читаются.';
  const buttons = [{label:'Закрыть'}];
  if (st.ready) buttons.push({label:'Проверка безопасности', value:'check'}, {label:'Мои сеансы', value:'devices'}, {label:'Экспорт ключей', value:'export'}, {label:'Импорт ключей', value:'import'});
  if (st.ready && !st.hasCS) buttons.push({label:'Настроить', value:'setup'});
  if (st.ready && st.hasCS) {
    buttons.push({label:'Ввести ключ восстановления', value:'key'});
    if (!st.verified) buttons.push({label:'Подтвердить с другого устройства', value:'device'});
    else buttons.push({label:'Восстановить ключи из копии', value:'backup'});
  }
  if (st.ready) buttons.push({label:strict ? 'Защищённый режим: выключить' : 'Защищённый режим: включить', value:'strict'});
  const v = await modal({title:'Шифрование', html:`<p>${esc(status)}</p>
    <p style="font-size:13px">Защищённый режим ${strict ? '<b>включён</b>' : 'выключен'}: ${strict ? 'ключи от сообщений получают только устройства, подтверждённые их владельцами. Вход по украденному паролю переписку не откроет' : 'ключи получают все устройства собеседников, в том числе неподтверждённые, как в Element по умолчанию'}.</p>
    <p style="font-size:13px">Это устройство: <code>${esc(S.deviceId)}</code></p>`, buttons});
  if (v === 'setup') setupEncryption();
  else if (v === 'key') recoveryKeyFlow();
  else if (v === 'device') requestDeviceVerification();
  else if (v === 'backup') restoreBackup();
  else if (v === 'check') securityCheck();
  else if (v === 'devices') sessionsDialog();
  else if (v === 'export') exportKeys();
  else if (v === 'import') importKeys();
  else if (v === 'strict') {
    const on = !strict;
    if (!on) {
      const ok = await modal({title:'Выключить защищённый режим?', html:'<p>Ключи от ваших новых сообщений начнут получать и неподтверждённые устройства — например, вошедшие по украденному паролю. Рекомендуем оставить режим включённым.</p>', buttons:[{label:'Отмена'}, {label:'Выключить', value:true}]});
      if (!ok) return;
    }
    localStorage.setItem(LS_STRICT, on ? '1' : '0'); applyStrict();
    toast(on ? 'Защищённый режим включён' : 'Защищённый режим выключен');
  }
}
async function myDevices(){
  const c = crypto_();
  let list = [];
  try { list = (await S.client.getDevices()).devices || []; } catch (e) { toast('Не удалось получить список: ' + e.message); return; }
  list.sort((a, b) => (b.last_seen_ts || 0) - (a.last_seen_ts || 0));
  const rows = [];
  for (const d of list) {
    let ok = false;
    try { ok = !!(await c?.getDeviceVerificationStatus(S.userId, d.device_id))?.crossSigningVerified; } catch {}
    const seen = d.last_seen_ts ? new Date(d.last_seen_ts).toLocaleString('ru-RU') : 'нет данных';
    rows.push(`<div class="chk"><span>${ok ? '✅' : '⚠️'}</span><div><b>${esc(d.display_name || 'Без названия')}</b>${d.device_id === S.deviceId ? ' — <i>это устройство</i>' : ''}<br><small>${esc(d.device_id)} · ${esc(seen)}${d.last_seen_ip ? ' · ' + esc(d.last_seen_ip) : ''}</small><br><small>${ok ? 'Подтверждено' : 'Не подтверждено'}</small></div></div>`);
  }
  modal({title:'Мои устройства', html:`<p>Все входы в ваш аккаунт. Если видите незнакомое устройство, завершите его сеанс в Element (Настройки → Сеансы) и смените пароль.</p>${rows.join('')}`, buttons:[{label:'Закрыть', value:true}]});
}
async function securityCheck(){
  toast('Проверяем…', true);
  const c = crypto_(), res = [];
  const add = (lvl, text) => res.push([lvl, text]);
  add(c ? 'ok' : 'bad', c ? 'Сквозное шифрование работает (' + esc(c.getVersion?.() || 'Rust crypto') + ')' : 'Модуль шифрования не загрузился');
  add(window.isSecureContext ? 'ok' : 'bad', window.isSecureContext ? 'Защищённый контекст: ключи изолированы от сайтов и других программ' : 'Небезопасный контекст: откройте клиент по https или с localhost');
  add(/^https:/i.test(S.hs) ? 'ok' : 'bad', (/^https:/i.test(S.hs) ? 'Соединение с сервером по HTTPS: ' : 'Соединение без HTTPS: ') + esc(S.hs));
  if (c) {
    const st = await c.getDeviceVerificationStatus(S.userId, S.deviceId).catch(() => null);
    add(st?.crossSigningVerified ? 'ok' : 'warn', st?.crossSigningVerified ? 'Этот вход подтверждён кросс-подписью' : 'Этот вход не подтверждён — подтвердите его ключом восстановления или через Element');
    const csReady = await c.isCrossSigningReady?.().catch(() => false);
    add(csReady ? 'ok' : 'warn', csReady ? 'Кросс-подпись настроена' : 'Кросс-подпись не настроена на этом устройстве');
    const ssReady = await c.isSecretStorageReady?.().catch(() => false);
    add(ssReady ? 'ok' : 'warn', ssReady ? 'Ключ восстановления настроен' : 'Ключ восстановления не настроен или недоступен');
    const bv = await c.getActiveSessionBackupVersion?.().catch(() => null);
    add(bv ? 'ok' : 'warn', bv ? `Резервная копия ключей включена (версия ${esc(bv)})` : 'Резервная копия ключей не включена: при потере всех устройств старая переписка пропадёт');
    add(strictOn() ? 'ok' : 'warn', strictOn() ? 'Защищённый режим: ключи получают только подтверждённые владельцами устройства' : 'Ключи получают и неподтверждённые устройства (как в Element). Включите защищённый режим');
  }
  const joined = S.client.getRooms().filter(r => membership(r) === 'join' && !r.isSpaceRoom());
  const plain = joined.filter(r => !isEncrypted(r));
  add(plain.length ? 'warn' : 'ok', plain.length ? `Без шифрования ${plain.length} из ${joined.length} чатов: ${esc(plain.slice(0, 5).map(roomName).join(', '))}${plain.length > 5 ? '…' : ''}. Включить можно в информации о чате.` : `Все ${joined.length} чатов зашифрованы`);
  try {
    const t = new TextEncoder().encode('self-test ' + Date.now());
    const {data, info} = await encryptAttachment(t);
    const back = new Uint8Array(await decryptAttachment(data, info));
    const bad = new Uint8Array(data.slice(0)); bad[0] ^= 1;
    let tamper = false; try { await decryptAttachment(bad.buffer, info); } catch { tamper = true; }
    const same = back.length === t.length && back.every((x, i) => x === t[i]);
    add(same && tamper ? 'ok' : 'bad', same && tamper ? 'Шифрование файлов (AES-256-CTR + SHA-256): самопроверка и защита от подмены пройдены' : 'Самопроверка шифрования файлов не пройдена');
  } catch (e) { add('bad', 'Самопроверка шифрования файлов: ' + esc(e.message)); }
  try {
    const devs = (await S.client.getDevices()).devices || [];
    let unv = 0;
    for (const d of devs) { const s = await c?.getDeviceVerificationStatus(S.userId, d.device_id).catch(() => null); if (!s?.crossSigningVerified) unv++; }
    add(unv ? 'warn' : 'ok', unv ? `Неподтверждённых устройств в аккаунте: ${unv} из ${devs.length}. Проверьте список в «Мои сеансы»` : `Все ${devs.length} устройств аккаунта подтверждены`);
  } catch {}
  if (IS_ELECTRON) {
    add(S.secure.available ? 'ok' : 'bad', S.secure.available ? `Токен входа хранится зашифрованным (${esc(S.secure.backend)})` : 'Системное хранилище ключей недоступно — токен хранится без защиты');
    add(S.secure.storeEncrypted ? 'ok' : 'warn', S.secure.storeEncrypted ? 'База ключей шифрования на диске зашифрована ключом из ' + esc(S.secure.backend) + ', как в Element Desktop'
      : S.secure.legacy ? 'База ключей этого входа создана старой версией без шифрования. Проверьте резервную копию ключей (или сделайте экспорт), затем выйдите и войдите заново' : 'База ключей на диске не зашифрована');
    add('ok', 'Приложение изолировано: песочница, CSP, без webview и DevTools, защита от запуска с подменой кода (Electron Fuses)');
  } else add('warn', 'Веб-версия: ключи и токен хранятся в браузере без дополнительного шифрования. Надёжнее — приложение для Mac/Windows');
  $('#toast').hidden = true;
  const icon = {ok:'✅', warn:'⚠️', bad:'❌'};
  const html = `<p>Проверка выполняется на этом устройстве. Ключи никуда не отправляются.</p>${res.map(([l, t]) => `<div class="chk"><span>${icon[l]}</span><div>${t}</div></div>`).join('')}`;
  const v = await modal({title:'Проверка безопасности', html, buttons:[{label:'Мои сеансы', value:'devices'}, {label:'Закрыть', value:true}]});
  if (v === 'devices') sessionsDialog();
}
$('#cbanner').addEventListener('click', e => {
  const b = e.target.closest('[data-c]'); if (!b) return;
  if (b.dataset.c === 'key') recoveryKeyFlow();
  else if (b.dataset.c === 'device') requestDeviceVerification();
  else if (b.dataset.c === 'setup') setupEncryption();
});

/* ---------- menu & room actions ---------- */
const serverName = () => S.userId.split(':').slice(1).join(':');
function normUser(uid){ uid = uid.trim(); if (!uid.startsWith('@')) uid = '@' + uid; if (!uid.includes(':')) uid += ':' + serverName(); return uid; }
function renderMenu(){
  const dark = document.documentElement.dataset.theme === 'dark';
  $('#menu').innerHTML = `<div class="dd-me" data-m="profile" role="button" style="cursor:pointer">${avatarHTML(S.me.avatar, S.userId, S.me.name || localpart(S.userId), 42)}<div style="min-width:0"><div class="n">${esc(S.me.name || localpart(S.userId))}</div><div class="u">${esc(S.userId)}</div></div></div>
    <button class="mi" data-m="dm">${I_('chat')}Написать пользователю</button>
    <button class="mi" data-m="group">${I_('users')}Создать группу</button>
    <button class="mi" data-m="join">${I_('search')}Найти группу</button>
    <button class="mi" data-m="profile">${I_('user')}Мой профиль</button>
    <button class="mi" data-m="sessions">${I_('monitor')}Мои сеансы</button>
    <button class="mi" data-m="export">${I_('upload')}Экспорт ключей</button>
    <button class="mi" data-m="settings">${I_('sliders')}Настройки</button>
    <button class="mi" data-m="crypto">${I_('lock')}Шифрование и ключи</button>
    <button class="mi" data-m="theme">${I_('moon')}${dark ? 'Светлая тема' : 'Тёмная тема'}</button>
    <button class="mi danger" data-m="logout">${I_('logout')}Выйти</button>`;
  hydrate($('#menu'));
}
$('#menu-btn').onclick = e => { e.stopPropagation(); const m = $('#menu'); if (m.hidden) { renderMenu(); m.hidden = false; } else m.hidden = true; };
$('#menu').addEventListener('click', e => {
  const b = e.target.closest('[data-m]'); if (!b) return;
  $('#menu').hidden = true; S.settingsNav = false;
  ({theme:() => setTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark', true),
    dm:newDM, group:newGroup, join:joinRoom, crypto:cryptoDialog, settings:settingsDialog, profile:profileDialog, sessions:sessionsDialog, export:exportKeys, logout})[b.dataset.m]?.();
});
const ENC_STATE = [{type:'m.room.encryption', state_key:'', content:{algorithm:'m.megolm.v1.aes-sha2'}}];
async function openWhenReady(roomId){
  for (let i = 0; i < 40 && !S.client.getRoom(roomId); i++) await new Promise(r => setTimeout(r, 250));
  openRoom(roomId);
}
/* ---------- выбор пользователей сервера ---------- */
async function serverUsers(){
  const dom = serverName(), me = S.userId, map = new Map();
  const add = (id, name, avatar) => {
    if (!id || id === me || id.split(':').slice(1).join(':') !== dom) return;
    const prev = map.get(id);
    map.set(id, {id, name:name || prev?.name || localpart(id), avatar:avatar || prev?.avatar || ''});
  };
  // администратор сервера видит полный список пользователей
  try {
    const r = await S.client.http.authedRequest('GET', '/_synapse/admin/v2/users', {limit:'1000', guests:'false', deactivated:'false'}, undefined, {prefix:''});
    for (const u of r?.users || []) if (!u.deactivated && !u.is_guest && !u.user_type) add(u.name, u.displayname, u.avatar_url);
  } catch {}
  // каталог пользователей сервера
  for (const term of [dom.split('.')[0], dom]) {
    try { const r = await S.client.searchUserDirectory({term, limit:500}); for (const u of r?.results || []) add(u.user_id, u.display_name, u.avatar_url); } catch {}
  }
  // все, с кем уже есть общие чаты
  for (const u of S.client.getUsers()) add(u.userId, u.displayName, u.avatarUrl);
  return map;
}
async function userExists(uid){
  try { await S.client.getProfileInfo(uid); return true; }
  catch (e) { return !(e?.httpStatus === 404 || e?.errcode === 'M_NOT_FOUND'); }
}
// multi=false → возвращает [userId] по клику; multi=true → отметить нескольких
function pickUsers({title, multi = false, exclude = [], okLabel = 'Готово', allowEmpty = false, note = ''}){
  return new Promise(async res => {
    const m = $('#modal'), ex = new Set(exclude), sel = new Set();
    let users = new Map(), q = '', searchT = 0, err = '';
    m.innerHTML = `<div class="dlg up-dlg" role="dialog" aria-modal="true"><div class="up-head"><button class="up-back" data-x="cancel" aria-label="Назад">${I.back || '←'}</button><h3>${esc(title)}</h3></div>
      ${note ? `<p>${note}</p>` : ''}
      <input class="field" id="up-q" placeholder="Имя или @логин" autocomplete="off" autocapitalize="off" spellcheck="false">
      <div class="up-err" id="up-err" hidden></div>
      <div class="up-list" id="up-list"><div class="up-empty">Загружаем пользователей сервера…</div></div>
      ${multi ? `<div class="dlg-btns"><button class="btn-flat" data-x="cancel">Отмена</button><button class="btn-flat" data-x="ok" id="up-ok">${esc(okLabel)}</button></div>` : ''}</div>`;
    m.hidden = false;
    const inp = m.querySelector('#up-q'); inp.focus();
    const done = v => { m.hidden = true; m.innerHTML = ''; m.onclick = null; document.removeEventListener('keydown', key, true); res(v); };
    const showErr = t => { const e = m.querySelector('#up-err'); if (!e) return; e.textContent = t; e.hidden = !t; };
    const okBtn = () => { const b = m.querySelector('#up-ok'); if (!b) return; b.textContent = okLabel + (sel.size ? ` (${sel.size})` : ''); b.disabled = !allowEmpty && !sel.size; };
    const draw = () => {
      const list = m.querySelector('#up-list'); if (!list) return;
      const t = norm(q.replace(/^@/, ''));
      const all = [...users.values()].filter(u => !ex.has(u.id) && (!t || norm(u.name).includes(t) || norm(u.id).includes(t)))
        .sort((a, b) => (sel.has(b.id) - sel.has(a.id)) || a.name.localeCompare(b.name, 'ru'));
      list.innerHTML = all.length ? all.slice(0, 300).map(u => `<div class="up-row${sel.has(u.id) ? ' on' : ''}" data-u="${esc(u.id)}" role="button">${avatarHTML(u.avatar, u.id, u.name, 40)}<div class="up-t"><div>${esc(noMxid(u.name))}</div></div>${multi ? '<span class="up-ck"></span>' : ''}</div>`).join('')
        : `<div class="up-empty">${q ? 'Никого не нашли на сервере ' + esc(serverName()) : 'Нет доступных пользователей'}</div>`;
      if (multi && !q && all.length) list.insertAdjacentHTML('afterbegin', `<button class="up-all" data-x="all">${all.every(u => sel.has(u.id)) ? 'Снять выделение' : 'Выбрать всех (' + all.length + ')'}</button>`);
      hydrate(list); okBtn();
    };
    const pick = async uid => {
      if (!multi) return done([uid]);
      sel.has(uid) ? sel.delete(uid) : sel.add(uid); draw();
    };
    // ввели точный @логин, которого нет в списке
    const tryTyped = async () => {
      const raw = inp.value.trim(); if (!raw) return false;
      const uid = normUser(raw);
      if (users.has(uid) && !ex.has(uid)) { await pick(uid); return true; }
      if (uid.split(':').slice(1).join(':') !== serverName()) { showErr('Писать можно только пользователям сервера ' + serverName()); return true; }
      if (uid === S.userId) { showErr('Это вы'); return true; }
      if (ex.has(uid)) { showErr('Этот пользователь уже в чате'); return true; }
      if (!(await userExists(uid))) { showErr(`Пользователя ${uid} нет на сервере`); return true; }
      users.set(uid, {id:uid, name:localpart(uid), avatar:''}); await pick(uid); return true;
    };
    const key = async e => {
      if (e.key === 'Escape') { e.stopPropagation(); done(null); }
      else if (e.key === 'Enter' && document.activeElement === inp) {
        e.preventDefault();
        const first = m.querySelector('.up-row');
        if (!multi && first && q && !/[:@]/.test(q)) return pick(first.dataset.u);
        if (await tryTyped()) return;
        if (multi && (sel.size || allowEmpty)) done([...sel]);
      }
    };
    document.addEventListener('keydown', key, true);
    inp.addEventListener('input', () => {
      q = inp.value.trim(); showErr(''); draw();
      clearTimeout(searchT);
      if (q.length >= 2) searchT = setTimeout(async () => {
        try {
          const r = await S.client.searchUserDirectory({term:q.replace(/^@/, ''), limit:50});
          let added = false;
          for (const u of r?.results || []) if (u.user_id !== S.userId && u.user_id.split(':').slice(1).join(':') === serverName() && !users.has(u.user_id)) { users.set(u.user_id, {id:u.user_id, name:u.display_name || localpart(u.user_id), avatar:u.avatar_url || ''}); added = true; }
          if (added && m.querySelector('#up-list')) draw();
        } catch {}
      }, 250);
    });
    m.onclick = e => {
      if (e.target === m) return done(null);
      const x = e.target.closest('[data-x]');
      if (x?.dataset.x === 'cancel') return done(null);
      if (x?.dataset.x === 'ok') { if (sel.size || allowEmpty) done([...sel]); return; }
      if (x?.dataset.x === 'all') {
        const t = [...m.querySelectorAll('.up-row')].map(r => r.dataset.u);
        const allOn = t.every(id => sel.has(id));
        t.forEach(id => allOn ? sel.delete(id) : sel.add(id)); draw(); return;
      }
      const r = e.target.closest('[data-u]'); if (r) pick(r.dataset.u);
    };
    okBtn();
    users = await serverUsers();
    draw();
  });
}
async function newDM(){
  const picked = await pickUsers({title:'Написать пользователю', note:'Выберите собеседника из пользователей сервера. Чат будет зашифрован.'});
  const uid = picked?.[0]; if (!uid) return;
  const existing = (S.dm[uid] || []).find(id => S.client.getRoom(id)?.getMyMembership() === 'join');
  if (existing) return openRoom(existing);
  try {
    const r = await S.client.createRoom({is_direct:true, invite:[uid], preset:'trusted_private_chat', initial_state:ENC_STATE});
    S.dm = {...S.dm, [uid]:[...(S.dm[uid] || []), r.room_id]};
    S.client.setAccountData('m.direct', S.dm).catch(() => {});
    openWhenReady(r.room_id);
  } catch (e) { toast('Не удалось создать чат: ' + e.message); }
}
async function newGroup(){
  const name = await modal({title:'Создать группу', html:'<p>Группа будет зашифрована.</p>', input:'Название группы', buttons:[{label:'Отмена'}, {label:'Далее', value:true}]});
  if (!name) return;
  const invite = await pickUsers({title:'Участники «' + name + '»', multi:true, okLabel:'Создать', allowEmpty:true, note:'Отметьте, кого пригласить. Можно никого — пригласить можно и позже.'});
  if (!invite) return;
  try { const r = await S.client.createRoom({name, preset:'private_chat', initial_state:ENC_STATE, invite}); openWhenReady(r.room_id); if (invite.length) toast('Группа создана, приглашений: ' + invite.length); }
  catch (e) { toast('Не удалось создать группу: ' + e.message); }
}
function roomAddr(raw){
  raw = raw.trim().replace(/\s+/g, '-');
  if (/^!/.test(raw)) return raw.includes(':') ? raw : raw + ':' + serverName();
  raw = raw.replace(/^#/, '');
  return '#' + raw + (raw.includes(':') ? '' : ':' + serverName());
}
const NO_GROUP = 'Такой группы нет на сервере. Проверьте название или попросите участника группы прислать приглашение.';
async function joinByName(raw){
  const addr = roomAddr(raw);
  try {
    if (addr.startsWith('#')) {
      try { await S.client.getRoomIdForAlias(addr); }
      catch (e) { if (e?.httpStatus === 404 || e?.errcode === 'M_NOT_FOUND') { await modal({title:'Группа не найдена', html:`<p>${NO_GROUP}</p>`, buttons:[{label:'Понятно'}]}); return; } }
    }
    const r = await S.client.joinRoom(addr); openWhenReady(r.roomId);
  } catch (e) {
    const code = e?.errcode, st = e?.httpStatus;
    const msg = code === 'M_NOT_FOUND' || st === 404 || /not legal room|unknown room|no known servers/i.test(e?.message || '') ? NO_GROUP
      : code === 'M_FORBIDDEN' || st === 403 ? 'Это закрытая группа — войти можно только по приглашению.'
      : esc(e?.message || String(e));
    modal({title:'Не удалось войти', html:`<p>${msg}</p>`, buttons:[{label:'Понятно'}]});
  }
}
// «Найти группу»: открытые группы сервера + вход по названию
function joinRoom(){
  const m = $('#modal');
  let rooms = [], q = '';
  m.innerHTML = `<div class="dlg up-dlg" role="dialog" aria-modal="true">${dlgHead('Найти группу', 'data-x="cancel"')}
    <input class="field" id="up-q" placeholder="Введите название группы" autocomplete="off" autocapitalize="off" spellcheck="false">
    <div class="up-list" id="up-list"><div class="up-empty">Загружаем открытые группы…</div></div>
    <div class="dlg-btns"><button class="btn-flat" data-x="cancel">Отмена</button><button class="btn-flat" data-x="ok">Войти</button></div></div>`;
  m.hidden = false;
  const inp = m.querySelector('#up-q'); inp.focus();
  const close = () => { m.hidden = true; m.innerHTML = ''; m.onclick = null; document.removeEventListener('keydown', key, true); };
  const draw = () => {
    const list = m.querySelector('#up-list'); if (!list) return;
    const t = norm(q);
    const f = rooms.filter(r => !t || norm(r.name).includes(t) || norm(r.canonical_alias).includes(t) || norm(r.topic).includes(t));
    list.innerHTML = f.length ? f.slice(0, 200).map(r => {
      const joined = S.client.getRoom(r.room_id)?.getMyMembership() === 'join';
      return `<div class="up-row" data-r="${esc(r.room_id)}" role="button">${avatarHTML(r.avatar_url || '', r.room_id, r.name || localpart(r.canonical_alias) || 'Группа', 40)}<div class="up-t"><div>${esc(r.name || localpart(r.canonical_alias) || 'Без названия')}</div><div class="u">${esc(plural(r.num_joined_members || 0, ['участник', 'участника', 'участников']))}${joined ? ' · вы в группе' : ''}${r.topic ? ' · ' + esc(r.topic) : ''}</div></div></div>`;
    }).join('') : `<div class="up-empty">${q ? 'Среди открытых групп такой нет — нажмите «Войти», чтобы найти группу по точному названию' : 'Открытых групп на сервере нет. Введите название группы.'}</div>`;
    hydrate(list);
  };
  const go = async () => {
    const raw = inp.value.trim();
    if (!raw) { inp.focus(); return; }
    close(); joinByName(raw);
  };
  const key = e => {
    if (e.key === 'Escape') { e.stopPropagation(); close(); }
    else if (e.key === 'Enter' && document.activeElement === inp) { e.preventDefault(); go(); }
  };
  document.addEventListener('keydown', key, true);
  inp.addEventListener('input', () => { q = inp.value.trim(); draw(); });
  m.onclick = async e => {
    if (e.target === m) return close();
    const x = e.target.closest('[data-x]');
    if (x?.dataset.x === 'cancel') return close();
    if (x?.dataset.x === 'ok') return go();
    const r = e.target.closest('[data-r]'); if (!r) return;
    const id = r.dataset.r; close();
    if (S.client.getRoom(id)?.getMyMembership() === 'join') return openRoom(id);
    try { await S.client.joinRoom(id); openWhenReady(id); }
    catch (err) { modal({title:'Не удалось войти', html:`<p>${err?.errcode === 'M_FORBIDDEN' ? 'Это закрытая группа — войти можно только по приглашению.' : esc(err?.message || String(err))}</p>`, buttons:[{label:'Понятно'}]}); }
  };
  (async () => {
    try {
      let since, n = 0;
      do { const r = await S.client.publicRooms({limit:100, since}); rooms.push(...(r.chunk || [])); since = r.next_batch; } while (since && ++n < 5);
    } catch {}
    rooms.sort((a, b) => (b.num_joined_members || 0) - (a.num_joined_members || 0));
    draw();
  })();
}
async function showInfo(){
  const room = cur(); if (!room) return;
  await room.loadMembersIfNeeded?.().catch(() => {});
  const members = room.getJoinedMembers();
  const dm = isDM(room), c = crypto_();
  const partner = dm ? (dmPartnerOf(room) || room.getAvatarFallbackMember()?.userId) : null;
  let partnerLine = '', partnerVerified = false;
  if (partner && c && isEncrypted(room)) {
    try { partnerVerified = !!(await c.getUserVerificationStatus(partner))?.isVerified?.(); } catch {}
    partnerLine = `<div class="info-row"><small>Проверка собеседника</small>${partnerVerified ? '✅ Собеседник подтверждён — его устройства проверены' : '⚠️ Собеседник не подтверждён. Сравните с ним эмодзи, чтобы исключить подмену ключей.'}</div>`;
  }
  const verified = new Map();
  if (c && !dm) await Promise.all(members.slice(0, 50).map(m => c.getUserVerificationStatus(m.userId).then(s => verified.set(m.userId, !!s?.isVerified?.())).catch(() => {})));
  const memHTML = members.slice(0, 100).map(m => `<div class="mem">${avatarHTML(m.getMxcAvatarUrl() || '', m.userId, m.name, 36)}<div style="min-width:0"><div>${esc(memberName(room, m.userId))}${verified.get(m.userId) ? ' ✅' : ''}</div></div></div>`).join('');
  const topic = room.currentState.getStateEvents('m.room.topic', '')?.getContent()?.topic;
  const alias = room.getCanonicalAlias();
  const html = `<div class="info-top">${roomAvatar(room, 84)}<div class="nm">${esc(roomName(room))}</div><div style="color:var(--muted);font-size:14px">${isEncrypted(room) ? '🔒 Сквозное шифрование включено' : '⚠️ Без шифрования'}</div></div>
    ${partnerLine}
    ${topic ? `<div class="info-row"><small>Описание</small>${linkify(esc(topic))}</div>` : ''}
    ${alias ? `<div class="info-row"><small>Адрес</small><code>${esc(alias)}</code></div>` : ''}
    <div class="info-row"><small>Автоудаление сообщений</small>${roomTTL(room) ? '🔥 ' + esc(ttlText(roomTTL(room))) : 'Выключено'}</div>
    ${!dm && members.length ? `<div class="info-row"><small>${esc(plural(members.length, ['участник','участника','участников']))}</small>${memHTML}</div>` : ''}`;
  const buttons = [{label:membership(room) === 'invite' ? 'Отклонить' : 'Покинуть чат', value:'leave', danger:true}];
  if (partner && c && isEncrypted(room) && !partnerVerified && membership(room) === 'join') buttons.push({label:'Подтвердить собеседника', value:'verify'});
  if (!dm && membership(room) === 'join') buttons.push({label:'Пригласить', value:'invite'});
  buttons.unshift({label:'Медиа, файлы и ссылки', value:'media'});
  if (membership(room) === 'join') buttons.push({label:'Автоудаление', value:'ttl'});
  if (alias) buttons.push({label:'Скопировать адрес группы', value:'copyalias'});
  if (!isEncrypted(room) && membership(room) === 'join') buttons.push({label:'Включить шифрование', value:'encrypt'});
  buttons.push({label:'Закрыть'});
  const p = modal({title:dm ? 'Информация' : 'О группе', html, buttons});
  hydrate($('#modal'));
  const v = await p;
  if (v === 'leave') leaveRoom(room);
  else if (v === 'invite') invite(room);
  else if (v === 'encrypt') enableEncryption(room);
  else if (v === 'ttl') autoDeleteDialog(room);
  else if (v === 'media') mediaDialog(room);
  else if (v === 'copyalias') navigator.clipboard?.writeText(alias).then(() => toast('Адрес скопирован'), () => toast('Не удалось скопировать'));
  else if (v === 'verify') {
    try { verifyFlow(await c.requestVerificationDM(partner, room.roomId)); }
    catch (e) { toast('Не удалось отправить запрос: ' + (e.message || e)); }
  }
}
// ---------- медиа, файлы и ссылки чата ----------
async function mediaDialog(room, tab = 'media', loaded = false){
  if (!loaded) {
    toast('Собираем медиа и файлы…', true);
    for (let i = 0; i < 6 && !uiOf(room.roomId).reachedStart; i++) await older(room);
    $('#toast').hidden = true;
  }
  const evs = liveEvents(room).filter(ev => isMsg(ev) && !ev.isRedacted() && !isExpired(ev) && !ev.isDecryptionFailure()).reverse();
  const media = [], files = [], links = [];
  for (const ev of evs) {
    const c = ev.getContent() || {}, t = c.msgtype;
    if (t === 'm.image' || t === 'm.video') media.push(ev);
    else if (t === 'm.file' || (t === 'm.audio' && !c['org.matrix.msc3245.voice'])) files.push(ev);
    else if (t === 'm.text' || t === 'm.notice') for (const u of (stripReply(c.body).match(/https?:\/\/[^\s<]+[^\s<.,;:!?)\]'"]/g) || [])) links.push({ev, u});
  }
  const tabs = [['media', 'Медиа', media.length], ['files', 'Файлы', files.length], ['links', 'Ссылки', links.length]];
  const day = ev => new Date(ev.getTs()).toLocaleDateString('ru-RU');
  let body;
  if (tab === 'media') body = media.length ? `<div class="mg">${media.map(ev => { const c = ev.getContent(); const img = c.msgtype === 'm.image';
      const attrs = c.file ? ` data-ev="${esc(ev.getId())}" data-room="${esc(room.roomId)}"` : c.url ? ` data-mxc="${esc(c.url)}" data-thumb="256"` : '';
      return `<button class="mg-i" data-v="view:${esc(ev.getId())}">${img ? `<img alt=""${attrs}>` : '<span class="mg-vid">🎬</span>'}</button>`; }).join('')}</div>` : '<div class="up-empty">Фото и видео пока нет</div>';
  else if (tab === 'files') body = files.length ? files.map(ev => { const c = ev.getContent(); return `<button class="st-row" data-v="dl:${esc(ev.getId())}"><span class="st-ic">${c.msgtype === 'm.audio' ? '🎵' : '📄'}</span><span class="st-t"><span>${esc(c.filename || c.body || 'Файл')}</span><small>${esc([fmtSize(c.info?.size), memberName(room, ev.getSender()), day(ev)].filter(Boolean).join(' · '))}</small></span><span class="st-r">${I.download}</span></button>`; }).join('') : '<div class="up-empty">Файлов пока нет</div>';
  else body = links.length ? links.map(({ev, u}, i) => { let h = u; try { h = new URL(u).hostname; } catch {} return `<button class="st-row" data-v="link:${i}"><span class="st-ic">🔗</span><span class="st-t"><span>${esc(h)}</span><small style="word-break:break-all">${esc(u.length > 90 ? u.slice(0, 90) + '…' : u)}</small></span></button>`; }).join('') : '<div class="up-empty">Ссылок пока нет</div>';
  const more = !uiOf(room.roomId).reachedStart ? '<button class="sr-more" data-v="more">Загрузить более ранние</button>' : '';
  panel(`<h3>Медиа и файлы</h3><div class="mtabs">${tabs.map(([id, t, n]) => `<button class="${tab === id ? 'on' : ''}" data-v="tab:${id}">${t}${n ? ' ' + n : ''}</button>`).join('')}</div><div class="mbody">${body}${more}</div>`, async v => {
    const [a, x] = v.split(/:(.*)/s);
    if (a === 'tab') return mediaDialog(room, x, true);
    if (a === 'more') { for (let i = 0; i < 4 && !uiOf(room.roomId).reachedStart; i++) await older(room); return mediaDialog(room, tab, true); }
    if (a === 'view') { const ev = room.findEventById(x); closePanel(); if (ev) openViewer(room, ev); }
    if (a === 'dl') { const ev = room.findEventById(x); if (ev) downloadEvent(ev); }
    if (a === 'link') { const l = links[+x]; if (l) safeOpen(l.u, l.u); }
  }, {back:true, cls:'st-dlg md-dlg'});
  hydrate($('#modal'));
}
async function enableEncryption(room){
  const ok = await modal({title:'Включить шифрование?', html:'<p>Отключить его потом будет нельзя. Участники со старыми клиентами без шифрования перестанут видеть новые сообщения.</p>', buttons:[{label:'Отмена'}, {label:'Включить', value:true}]});
  if (!ok) return;
  try { await S.client.sendStateEvent(room.roomId, 'm.room.encryption', ENC_STATE[0].content, ''); toast('Шифрование включено'); }
  catch (e) { toast('Не удалось: ' + e.message); }
}
async function invite(room){
  await room.loadMembersIfNeeded?.().catch(() => {});
  const ex = room.getMembers().filter(m => ['join', 'invite'].includes(m.membership)).map(m => m.userId);
  const list = await pickUsers({title:'Пригласить в «' + roomName(room) + '»', multi:true, exclude:ex, okLabel:'Пригласить'});
  if (!list?.length) return;
  let ok = 0; const bad = [];
  for (const uid of list) {
    toast(`Приглашаем… ${ok + bad.length + 1} из ${list.length}`, true);
    try { await S.client.invite(room.roomId, uid); ok++; } catch (e) { bad.push(localpart(uid)); }
  }
  toast(bad.length ? `Приглашено: ${ok}. Не удалось: ${bad.join(', ')}` : `Приглашено: ${ok}`);
}
async function leaveRoom(room){
  if (membership(room) === 'join') {
    const ok = await modal({title:'Покинуть «' + roomName(room) + '»?', buttons:[{label:'Отмена'}, {label:'Покинуть', value:true, danger:true}]});
    if (!ok) return;
  }
  try { await S.client.leave(room.roomId); if (S.current === room.roomId) closeChat(); schedule(); }
  catch (e) { toast('Не удалось: ' + e.message); }
}
async function acceptInvite(room){
  try { await S.client.joinRoom(room.roomId); toast('Вы вступили в чат'); schedule(); }
  catch (e) { toast('Не удалось принять: ' + e.message); }
}

/* ---------- emoji & sticker picker ---------- */
const EMOJI = [
  ['😀', 'Смайлы', '😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😙 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🤫 🤔 🤐 🤨 😐 😑 😶 😏 😒 🙄 😬 😮‍💨 🤥 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🥵 🥶 🥴 😵 🤯 🤠 🥳 😎 🤓 🧐 😕 😟 🙁 😮 😯 😲 😳 🥺 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 😡 😠 🤬 😈 👿 💀 💩 🤡 👻 👽 🤖 😺 😸 😹 😻 😼 😽 🙀 😿 😾'],
  ['👍', 'Жесты и люди', '👋 🤚 🖐 ✋ 🖖 👌 🤌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 👐 🤲 🤝 🙏 ✍️ 💅 💪 👀 👁 👅 👄 🧠 🫶 👶 🧒 👦 👧 🧑 👱 👨 🧔 👩 🧓 👴 👵 🙍 🙎 🙅 🙆 💁 🙋 🙇 🤦 🤷 👮 🕵️ 💂 👷 🤴 👸 🧑‍💻 🧑‍🔧 🧑‍🍳 🧑‍🎓 🧑‍⚕️ 🧑‍🏫 🏃 🚶 💃 🕺 👯 🧘 🛌 👫 👪'],
  ['❤️', 'Сердца и символы', '❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💯 💢 💥 💫 💦 💨 💬 💭 💤 ✅ ☑️ ✔️ ❌ ❎ ➕ ➖ ❗ ❓ ‼️ ⁉️ ⚠️ 🚫 ⛔ ♻️ 🔥 ✨ ⭐ 🌟 ⚡ 🎵 🎶 🔔 🔕 📌 📍 🔒 🔓 🔑 🆗 🆕 🆒 🆘 ▶️ ⏸ ⏹ 🔴 🟠 🟡 🟢 🔵 🟣 ⚫ ⚪'],
  ['🐶', 'Животные и природа', '🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐔 🐧 🐦 🐤 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝 🐛 🦋 🐌 🐞 🐜 🐢 🐍 🦎 🐙 🦑 🦀 🐠 🐟 🐬 🐳 🐋 🦈 🐊 🐅 🐆 🦓 🐘 🦒 🦘 🐪 🐄 🐎 🐖 🐑 🐐 🦌 🐕 🐈 🐓 🦃 🕊 🐇 🦔 🐾 🌵 🎄 🌲 🌳 🌴 🌱 🌿 ☘️ 🍀 🍁 🍂 🍃 🌷 🌹 🥀 🌺 🌸 🌼 🌻 🌞 🌝 🌚 🌙 🌎 🪐 ☀️ ⛅ ☁️ 🌧 ⛈ ❄️ ☃️ ⛄ 🌈 🌊'],
  ['🍕', 'Еда и напитки', '🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🥦 🥬 🥒 🌶 🌽 🥕 🧄 🧅 🥔 🥐 🥯 🍞 🥖 🧀 🥚 🍳 🧈 🥞 🧇 🥓 🥩 🍗 🍖 🌭 🍔 🍟 🍕 🥪 🌮 🌯 🥗 🍝 🍜 🍲 🍛 🍣 🍱 🥟 🍤 🍙 🍚 🍰 🎂 🧁 🍮 🍭 🍬 🍫 🍿 🍩 🍪 🍯 ☕ 🍵 🧃 🥤 🧋 🍺 🍻 🥂 🍷 🥃 🍸 🍹 🍾 🧊'],
  ['⚽', 'Занятия', '⚽ 🏀 🏈 ⚾ 🎾 🏐 🏉 🎱 🏓 🏸 🏒 🥊 🥋 ⛳ ⛸ 🎣 🎿 🛷 🏂 🏋️ 🤸 🤺 🏊 🚴 🧗 🏆 🥇 🥈 🥉 🏅 🎖 🎫 🎪 🎭 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🎷 🎺 🎸 🎻 🎲 ♟ 🎯 🎳 🎮 🕹 🧩 🎉 🎊 🎈 🎁 🎀'],
  ['🚗', 'Транспорт и места', '🚗 🚕 🚙 🚌 🚎 🏎 🚓 🚑 🚒 🚐 🚚 🚛 🚜 🏍 🛵 🚲 🛴 🚨 🚍 ✈️ 🛫 🛬 🚀 🛸 🚁 ⛵ 🚤 🛳 🚢 ⚓ 🚂 🚆 🚇 🚊 🗺 🗽 🗼 🏰 🏯 🏟 🎡 🎢 🎠 ⛲ 🏖 🏝 🏜 🌋 ⛰ 🏔 🏕 🏠 🏡 🏢 🏬 🏥 🏦 🏨 🏪 🏫 ⛪ 🕌 🌃 🌆 🌇 🌉 🌌 🎆 🎇'],
  ['💡', 'Предметы', '⌚ 📱 💻 ⌨️ 🖥 🖨 🖱 💾 💿 📷 📸 📹 🎥 📞 ☎️ 📺 📻 🎙 ⏰ ⏳ ⌛ 📡 🔋 🔌 💡 🔦 🕯 🧯 💸 💵 💳 💎 ⚖️ 🧰 🔧 🔨 🛠 ⛏ 🔩 ⚙️ 🧱 🧲 💣 🔪 🛡 🔮 🔭 🔬 💊 💉 🧬 🦠 🧪 🌡 🧹 🧺 🧻 🧼 🗝 🚪 🛋 🛏 🧸 🖼 🛍 🛒 ✉️ 📩 📦 📫 📜 📄 📑 📊 📈 📉 🗓 📆 📋 📁 📂 📰 📓 📒 📚 📖 🔖 🔗 📎 📐 📏 ✂️ 🖊 🖌 📝 ✏️ 🔍 🔎'],
  ['🏁', 'Флаги', '🇷🇺 🇧🇾 🇰🇿 🇺🇦 🇦🇲 🇦🇿 🇬🇪 🇺🇿 🇰🇬 🇹🇯 🇹🇲 🇲🇩 🇨🇳 🇮🇳 🇹🇷 🇦🇪 🇮🇱 🇯🇵 🇰🇷 🇹🇭 🇻🇳 🇮🇩 🇺🇸 🇨🇦 🇲🇽 🇧🇷 🇦🇷 🇬🇧 🇩🇪 🇫🇷 🇮🇹 🇪🇸 🇵🇹 🇳🇱 🇧🇪 🇨🇭 🇦🇹 🇵🇱 🇨🇿 🇸🇪 🇳🇴 🇫🇮 🇩🇰 🇬🇷 🇷🇸 🇪🇬 🇿🇦 🇦🇺 🏳️ 🏴 🏁 🚩'],
];
const LS_RECENT = 'mxtg.recentEmoji';
function recentEmoji(){ try { return JSON.parse(localStorage.getItem(LS_RECENT) || '[]'); } catch { return []; } }
function pushRecent(e){ try { localStorage.setItem(LS_RECENT, JSON.stringify([e, ...recentEmoji().filter(x => x !== e)].slice(0, 32))); } catch {} }
function openPicker(mode = 'insert', target = null, tab = null){
  S.picker = {mode, target, tab:mode === 'react' ? 'emoji' : (tab || S.picker?.tab || 'emoji')};
  renderPicker();
  $('#picker').hidden = false;
}
function closePicker(){ $('#picker').hidden = true; if (S.picker) S.picker.open = false; }
const BUILTIN_PACKS = [
  ['Ласточка', [['privet','Привет!'],['haha','Ха-ха!'],['lyublyu','Люблю'],['super','Супер!'],['ok','Ок'],['ura','Ура!'],['ogo','Ого!'],['spasibo','Спасибо!'],['kofe','Кофе?'],['grushchu','Грущу'],['zlyus','Злюсь'],['splyu','Сплю']]],
  ['Котик', [["c_privet", "Привет!"], ["c_mur", "Мур"], ["c_ok", "Окей"], ["c_utro", "Доброе утро"], ["c_noch", "Спокойной ночи"], ["c_obnim", "Обнимаю"], ["c_rabota", "Работаю"], ["c_zhdu", "Жду…"], ["c_ura", "Ура!"], ["c_ups", "Упс"], ["c_chto", "Что?!"], ["c_lyublyu", "Люблю тебя"], ["c_zlyus", "Сержусь"], ["c_spasibo", "Спасибо"], ["c_poka", "Пока!"], ["c_kushat", "Ням"]]],
  ['Эмоции', [["e_klass", "Класс!"], ["e_ogon", "Огонь!"], ["e_lyubov", "Люблю"], ["e_oru", "Ору"], ["e_plachu", "Плачу"], ["e_hm", "Хм…"], ["e_pozdr", "Поздравляю!"], ["e_bravo", "Браво!"], ["e_pozh", "Пожалуйста"], ["e_chetko", "Чётко"], ["e_shok", "Шок!"], ["e_100", "Точно"], ["e_dogovor", "Договорились"], ["e_ustal", "Устал"], ["e_facepalm", "Ну как так"], ["e_obnim", "Обнимаю"]]],
];
function builtinPacks(){
  return BUILTIN_PACKS.map(([name, list]) => {
    const images = {};
    for (const [k, body] of list) images['lastochka_' + k] = {local:`./stickers/${k}.png`, body, info:{w:512, h:512, mimetype:'image/png'}, usage:['sticker']};
    return {name, images, builtin:true};
  });
}
// встроенный стикер загружается на сервер один раз, дальше переиспользуется mxc-ссылка
function builtinCacheKey(){ return 'lastochka.stk.' + (S.client?.getUserId() || ''); }
async function builtinMxc(img){
  let cache = {};
  try { cache = JSON.parse(localStorage.getItem(builtinCacheKey()) || '{}'); } catch {}
  if (cache[img.local]) return cache[img.local];
  const blob = await (await fetch(img.local)).blob();
  const r = await S.client.uploadContent(blob, {name:img.local.split('/').pop(), type:'image/png'});
  cache[img.local] = r.content_uri;
  try { localStorage.setItem(builtinCacheKey(), JSON.stringify(cache)); } catch {}
  return r.content_uri;
}
function stickerPacks(){
  const packs = [...builtinPacks()];
  const own = S.client.getAccountData('im.ponies.user_emotes')?.getContent() || {};
  packs.push({name:'Мои стикеры', images:own.images || {}, own:true});
  const room = cur();
  for (const ev of room?.currentState.getStateEvents('im.ponies.room_emotes') || []) {
    const c = ev.getContent();
    if (c?.images && Object.keys(c.images).length) packs.push({name:c.pack?.display_name || 'Стикеры чата', images:c.images});
  }
  const er = S.client.getAccountData('im.ponies.emote_rooms')?.getContent()?.rooms || {};
  for (const [rid, keys] of Object.entries(er)) {
    const r = S.client.getRoom(rid);
    if (!r || rid === room?.roomId) continue;
    for (const sk of Object.keys(keys || {})) {
      const c = r.currentState.getStateEvents('im.ponies.room_emotes', sk)?.getContent();
      if (c?.images && Object.keys(c.images).length) packs.push({name:c.pack?.display_name || roomName(r), images:c.images});
    }
  }
  return packs;
}
const isStickerImg = img => (img?.url || img?.local) && (!Array.isArray(img.usage) || !img.usage.length || img.usage.includes('sticker'));
function renderPicker(){
  const p = $('#picker'), st = S.picker;
  const tabs = st.mode === 'react' ? '' : `<div class="pk-tabs"><button data-tab="emoji" class="${st.tab === 'emoji' ? 'on' : ''}">Эмодзи</button><button data-tab="stickers" class="${st.tab === 'stickers' ? 'on' : ''}">Стикеры</button></div>`;
  if (st.tab === 'emoji') {
    const rec = recentEmoji();
    const cats = (rec.length ? [['🕘', 'Недавние', rec.join(' ')]] : []).concat(EMOJI);
    p.innerHTML = tabs + `<div class="pk-cats">${cats.map((c, i) => `<button data-cat="${i}" title="${esc(c[1])}">${c[0]}</button>`).join('')}</div>
      <div class="pk-body">${cats.map((c, i) => `<div class="pk-h" id="pk-c${i}">${esc(c[1])}</div><div class="pk-grid">${c[2].split(' ').filter(Boolean).map(e => `<button class="pk-e" data-e="${e}">${e}</button>`).join('')}</div>`).join('')}</div>`;
    return;
  }
  st.packs = stickerPacks();
  p.innerHTML = tabs + `<div class="pk-body">${st.packs.map((pk, pi) => {
    const items = Object.entries(pk.images).filter(([, img]) => isStickerImg(img));
    return `<div class="pk-h">${esc(pk.name)}</div><div class="pk-sgrid">${pk.own ? '<button class="pk-add" title="Добавить стикер из файла">＋</button>' : ''}${items.map(([sc, img]) => `<button class="pk-s" data-pack="${pi}" data-sc="${esc(sc)}" title="${esc(img.body || sc)}">${img.local ? `<img alt="" src="${esc(img.local)}">` : `<img alt="" data-mxc="${esc(img.url)}" data-thumb="256">`}</button>`).join('')}</div>`;
  }).join('')}<div class="pk-note">Нажмите ＋, чтобы добавить картинку как стикер (PNG, WebP, GIF). Сохранить стикер или фото из чата можно через меню сообщения. Правый клик по своему стикеру удаляет его. Сами стикеры хранятся на сервере без шифрования, как в Element, но сообщение со стикером в зашифрованном чате шифруется.</div></div>`;
  hydrate(p);
}
function insertAtCursor(text){
  const t = $('#input');
  const s = t.selectionStart ?? t.value.length, e = t.selectionEnd ?? t.value.length;
  t.value = t.value.slice(0, s) + text + t.value.slice(e);
  const pos = s + text.length;
  t.focus(); t.setSelectionRange(pos, pos);
  autosize(); updateSendBtn();
}
async function sendSticker(img, sc){
  const room = cur(); if (!canSend(room)) return;
  closePicker();
  let url = img.url;
  if (!url && img.local) {
    try { url = await builtinMxc(img); } catch (e) { toast('Стикер не отправлен: ' + e.message); return; }
  }
  const content = {body:img.body || sc, url, info:{...(img.info || {})}};
  if (S.reply) { content['m.relates_to'] = {'m.in_reply_to':{event_id:S.reply}}; S.reply = null; renderBar(); }
  S.client.sendEvent(room.roomId, 'm.sticker', withTTL(room, content)).catch(e => toast('Стикер не отправлен: ' + e.message));
  schedule();
}
async function addToOwnPack(img){
  const prev = S.client.getAccountData('im.ponies.user_emotes')?.getContent() || {};
  const images = {...(prev.images || {})};
  if (Object.values(images).some(x => x.url === img.url)) { toast('Этот стикер уже есть'); return; }
  const base = String(img.body || 'sticker').replace(/\.[a-z0-9]+$/i, '').replace(/[^\p{L}\p{N}_-]+/gu, '_').slice(0, 32) || 'sticker';
  let sc = base, n = 1;
  while (images[sc]) sc = base + '_' + (++n);
  images[sc] = {url:img.url, body:img.body || sc, info:img.info || {}, usage:['sticker']};
  await S.client.setAccountData('im.ponies.user_emotes', {...prev, pack:{display_name:'Мои стикеры', ...(prev.pack || {})}, images});
  toast('Стикер добавлен');
}
async function removeFromOwnPack(sc){
  const prev = S.client.getAccountData('im.ponies.user_emotes')?.getContent() || {};
  const images = {...(prev.images || {})};
  delete images[sc];
  await S.client.setAccountData('im.ponies.user_emotes', {...prev, images});
}
async function addStickerFromFile(file){
  if (!/^image\/(png|jpeg|gif|webp)$/.test(file.type)) { toast('Подойдут PNG, JPEG, WebP или GIF'); return; }
  if (file.size > 2 * 1024 * 1024) { toast('Файл больше 2 МБ — уменьшите картинку'); return; }
  const info = {mimetype:file.type, size:file.size};
  try { const bmp = await createImageBitmap(file); info.w = bmp.width; info.h = bmp.height; bmp.close?.(); } catch {}
  toast('Загружаем стикер…', true);
  try {
    const r = await S.client.uploadContent(file, {name:file.name, type:file.type});
    await addToOwnPack({url:r.content_uri, body:file.name, info});
  } catch (e) { toast('Не удалось добавить стикер: ' + e.message); }
}
async function saveAsSticker(room, ev){
  const c = ev.getContent();
  if (c.url) return addToOwnPack({url:c.url, body:c.body, info:c.info}).catch(e => toast('Не удалось: ' + e.message));
  if (!c.file) return;
  const ok = await modal({title:'Сохранить в стикеры?', html:'<p>Картинка из зашифрованного чата будет загружена на сервер как стикер без шифрования.</p>', buttons:[{label:'Отмена'}, {label:'Сохранить', value:true}]});
  if (!ok) return;
  try {
    const u = await fetchEncrypted(c.file, c.info?.mimetype);
    const blob = await (await fetch(u)).blob();
    await addStickerFromFile(new File([blob], c.body || 'sticker.png', {type:safeMime(c.info?.mimetype)}));
  } catch (e) { toast('Не удалось: ' + e.message); }
}
$('#picker').addEventListener('click', e => {
  e.stopPropagation();
  const st = S.picker; if (!st) return;
  const tab = e.target.closest('[data-tab]');
  if (tab) { st.tab = tab.dataset.tab; renderPicker(); return; }
  const cat = e.target.closest('[data-cat]');
  if (cat) { $('#pk-c' + cat.dataset.cat)?.scrollIntoView({block:'start'}); return; }
  const em = e.target.closest('[data-e]');
  if (em) {
    pushRecent(em.dataset.e);
    if (st.mode === 'react') { const room = cur(); closePicker(); if (room && st.target) toggleReaction(room, st.target, em.dataset.e); }
    else insertAtCursor(em.dataset.e);
    return;
  }
  if (e.target.closest('.pk-add')) {
    const f = document.createElement('input'); f.type = 'file'; f.accept = 'image/png,image/jpeg,image/gif,image/webp';
    f.onchange = () => { if (f.files[0]) addStickerFromFile(f.files[0]); };
    f.click(); return;
  }
  const s = e.target.closest('[data-sc]');
  if (s) { const pk = st.packs?.[+s.dataset.pack]; const img = pk?.images[s.dataset.sc]; if (img) sendSticker(img, s.dataset.sc); }
});
$('#picker').addEventListener('contextmenu', async e => {
  const s = e.target.closest('[data-sc]'); if (!s) return;
  const pk = S.picker?.packs?.[+s.dataset.pack]; if (!pk?.own) return;
  e.preventDefault();
  const ok = await modal({title:'Удалить стикер?', buttons:[{label:'Отмена'}, {label:'Удалить', value:true, danger:true}]});
  if (ok) removeFromOwnPack(s.dataset.sc).catch(err => toast('Не удалось: ' + err.message));
});
function togglePicker(tab){
  if (!$('#picker').hidden && S.picker?.tab === tab && S.picker.mode === 'insert') return closePicker();
  openPicker('insert', null, tab);
}
$('#emoji-btn').onclick = e => { e.stopPropagation(); togglePicker('emoji'); };
$('#sticker-btn').onclick = e => { e.stopPropagation(); togglePicker('stickers'); };

/* ---------- passcode lock ---------- */
const LS_LOCK = 'mxtg.lock', LS_LOCKFAIL = 'mxtg.lockfail';
const AUTOLOCK = [[60e3, 'через 1 минуту'], [300e3, 'через 5 минут'], [900e3, 'через 15 минут'], [3600e3, 'через 1 час'], [0, 'не блокировать автоматически']];
const lockCfg = () => { try { return JSON.parse(localStorage.getItem(LS_LOCK) || 'null'); } catch { return null; } };
const autolockText = ms => (AUTOLOCK.find(a => a[0] === ms) || [0, 'не блокировать автоматически'])[1];
const b64u8 = buf => { const b = new Uint8Array(buf); let s = ''; for (const x of b) s += String.fromCharCode(x); return btoa(s); };
const u8b64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
async function hashPass(pass, salt, iterations){
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(pass), 'PBKDF2', false, ['deriveBits']);
  return b64u8(await crypto.subtle.deriveBits({name:'PBKDF2', hash:'SHA-256', salt, iterations}, key, 256));
}
async function checkPass(pass){
  const L = lockCfg(); if (!L) return true;
  return (await hashPass(pass, u8b64(L.salt), L.iter)) === L.hash;
}
async function savePass(pass, autolock){
  const salt = crypto.getRandomValues(new Uint8Array(16)), iter = 310000;
  localStorage.setItem(LS_LOCK, JSON.stringify({salt:b64u8(salt), iter, hash:await hashPass(pass, salt, iter), autolock}));
  updateLockBtn();
}
function failState(){ try { return JSON.parse(localStorage.getItem(LS_LOCKFAIL) || '{"n":0,"until":0}'); } catch { return {n:0, until:0}; } }
let lockTick;
function lockApp(){
  if (!lockCfg() || S.locked) return;
  S.locked = true;
  closeCtx(); closePicker(); cancelRecording(); P.audio.pause();
  closeViewer(); $('#menu').hidden = true;
  const el = $('#lock');
  el.innerHTML = `<div class="lock-card">
    <div class="logo"><svg width="56" height="56" viewBox="0 0 24 24" fill="currentColor"><path d="M17 9V7A5 5 0 007 7v2a2 2 0 00-2 2v8a2 2 0 002 2h10a2 2 0 002-2v-8a2 2 0 00-2-2zm-8 0V7a3 3 0 016 0v2z"/></svg></div>
    <h1>Ласточка</h1><p id="lock-msg">Введите код-пароль</p>
    <input class="field" id="lock-in" type="password" autocomplete="off" placeholder="Код-пароль">
    <button class="btn" id="lock-ok">Разблокировать</button>
    <button class="btn-flat" id="lock-forgot" style="margin-top:14px">Забыли код-пароль?</button></div>`;
  el.hidden = false;
  document.body.classList.add('locked');
  updateLockWait();
  clearInterval(lockTick); lockTick = setInterval(updateLockWait, 1000);
  setTimeout(() => $('#lock-in')?.focus(), 50);
}
function updateLockWait(){
  const f = failState(), left = Math.ceil((f.until - Date.now()) / 1000);
  const inp = $('#lock-in'), msg = $('#lock-msg'), ok = $('#lock-ok');
  if (!inp) return;
  const wait = left > 0;
  inp.disabled = wait; ok.disabled = wait;
  if (wait) msg.textContent = `Слишком много попыток. Подождите ${left >= 60 ? Math.ceil(left / 60) + ' мин' : left + ' с'}.`;
  else if (msg.dataset.err !== '1') msg.textContent = 'Введите код-пароль';
}
async function tryUnlock(){
  const inp = $('#lock-in'); if (!inp || inp.disabled) return;
  const f = failState();
  if (f.until > Date.now()) return;
  if (await checkPass(inp.value)) {
    localStorage.removeItem(LS_LOCKFAIL);
    S.locked = false; clearInterval(lockTick);
    $('#lock').hidden = true; $('#lock').innerHTML = '';
    document.body.classList.remove('locked');
    lastActivity = Date.now();
    schedule(); markRead(); renderCall();
    return;
  }
  f.n += 1;
  if (f.n >= 5) f.until = Date.now() + Math.min(3600e3, 30e3 * 2 ** (f.n - 5));
  localStorage.setItem(LS_LOCKFAIL, JSON.stringify(f));
  inp.value = '';
  const msg = $('#lock-msg'); msg.dataset.err = '1';
  msg.textContent = f.n >= 5 ? 'Неверный код-пароль' : `Неверный код-пароль. Осталось попыток до паузы: ${5 - f.n}`;
  inp.classList.remove('shake'); void inp.offsetWidth; inp.classList.add('shake');
  updateLockWait();
}
$('#lock').addEventListener('click', async e => {
  if (e.target.closest('#lock-ok')) return tryUnlock();
  if (e.target.closest('#lock-forgot')) {
    const el = $('#lock .lock-card');
    el.innerHTML = `<h1>Сбросить код-пароль?</h1><p>Код-пароль хранится только на этом устройстве, восстановить его нельзя. Можно выйти из аккаунта и войти заново — для этого понадобятся пароль от Matrix и ключ восстановления, чтобы вернуть зашифрованную переписку.</p>
      <button class="btn" id="lock-reset" style="background:var(--danger)">Выйти из аккаунта</button><button class="btn-flat" id="lock-back" style="margin-top:14px">Назад</button>`;
    return;
  }
  if (e.target.closest('#lock-back')) { S.locked = false; lockApp(); return; }
  if (e.target.closest('#lock-reset')) {
    localStorage.removeItem(LS_LOCK); localStorage.removeItem(LS_LOCKFAIL);
    loggingOut = true;
    try { await S.client?.logout(true); } catch {}
    try { await S.client?.clearStores(); } catch {}
    await wipeCryptoDB(); await clearSession(); location.reload();
  }
});
$('#lock').addEventListener('keydown', e => { if (e.key === 'Enter' && e.target.id === 'lock-in') tryUnlock(); });
let lastActivity = Date.now();
['pointerdown', 'keydown', 'wheel', 'touchstart'].forEach(n => document.addEventListener(n, () => { if (!S.locked) lastActivity = Date.now(); }, {passive:true, capture:true}));
let mmT = 0;
document.addEventListener('mousemove', () => { const now = Date.now(); if (now - mmT > 5000 && !S.locked) { mmT = now; lastActivity = now; } }, {passive:true});
setInterval(() => { const L = lockCfg(); if (L?.autolock && !S.locked && Date.now() - lastActivity > L.autolock) lockApp(); }, 10000);
window.desktop?.onSystemLock?.(() => lockApp());
function updateLockBtn(){ $('#lock-btn').hidden = !lockCfg(); }
$('#lock-btn').onclick = () => lockApp();
async function askNewPass(){
  const p1 = await modal({title:'Новый код-пароль', html:'<p>Не меньше 4 символов. Код хранится только на этом устройстве в виде хэша PBKDF2. Если его забыть, придётся заново войти в аккаунт.</p>', input:'Код-пароль', inputType:'password', buttons:[{label:'Отмена'}, {label:'Далее', value:true}]});
  if (!p1) return null;
  if (p1.length < 4) { toast('Код-пароль должен быть не короче 4 символов'); return null; }
  const p2 = await modal({title:'Повторите код-пароль', input:'Код-пароль ещё раз', inputType:'password', buttons:[{label:'Отмена'}, {label:'Готово', value:true}]});
  if (p2 == null) return null;
  if (p1 !== p2) { toast('Коды не совпадают'); return null; }
  return p1;
}
async function askAutolock(current){
  const v = await modal({title:'Автоблокировка', html:'<p>Через сколько минут бездействия блокировать приложение? Также оно блокируется при блокировке экрана компьютера и при каждом запуске.</p>',
    buttons:AUTOLOCK.map(([ms, t]) => ({label:(ms === current ? '✓ ' : '') + t[0].toUpperCase() + t.slice(1), value:String(ms)}))});
  return v == null ? null : +v;
}
async function verifyCurrent(){
  const p = await modal({title:'Текущий код-пароль', input:'Код-пароль', inputType:'password', buttons:[{label:'Отмена'}, {label:'Продолжить', value:true}]});
  if (p == null) return false;
  if (!(await checkPass(p))) { toast('Неверный код-пароль'); return false; }
  return true;
}
const BUILD_AT = typeof __BUILD_TIME__ !== 'undefined' ? __BUILD_TIME__ : '';
const APP_VER = typeof __APP_VERSION__ !== 'undefined' ? __APP_VERSION__ : '';
// Как в Element: старые версии со временем накапливают незакрытые уязвимости Electron/Chromium.
const buildOld = () => BUILD_AT && Date.now() - new Date(BUILD_AT).getTime() > 60 * 864e5;
function settingsDialog(){
  S.settingsNav = false;
  const L = lockCfg(), dark = document.documentElement.dataset.theme === 'dark', n = notifCfg();
  const row = (v, icon, t, sub, right = I.chevR) => `<button class="st-row" data-v="${v}"><span class="st-ic">${icon}</span><span class="st-t"><span>${t}</span>${sub ? `<small>${sub}</small>` : ''}</span><span class="st-r">${right}</span></button>`;
  const sw = on => `<span class="sw${on ? ' on' : ''}"></span>`;
  const html = `<div class="up-head"><button class="up-back" data-v="close" aria-label="Назад">${I.back}</button><h3>Настройки</h3></div>
    <div class="st-me">${avatarHTML(S.me.avatar, S.userId, S.me.name || localpart(S.userId), 56)}<div style="min-width:0"><div class="n">${esc(S.me.name || localpart(S.userId))}</div><div class="u">${esc(S.userId)}</div></div></div>
    <div class="st-h">Уведомления</div>
    ${row('n-on', ico('bell', '#ff453a'), 'Уведомления', '', sw(n.on))}
    ${n.on ? row('n-preview', ico('msg', '#0a84ff'), 'Показывать текст сообщения', '', sw(n.preview)) + row('n-sound', ico('sound', '#ff375f'), 'Звук', '', sw(n.sound)) + row('n-test', ico('check', '#32d74b'), 'Проверить уведомление', 'Если не появляется — разрешите уведомления для Ласточки в системе') : ''}
    <div class="st-h">Оформление</div>
    ${row('theme', ico('moon', '#5e5ce6'), 'Тёмная тема', '', sw(dark))}
    ${row('accent', ico('palette', '#ff9f0a'), 'Цвет акцента', esc((ACCENTS.find(a => a[0] === lookCfg().accent) || ACCENTS[0])[1]))}
    ${row('wall', ico('image', '#30b0c7'), 'Фон чатов', esc((WALLS.find(a => a[0] === lookCfg().wall) || WALLS[0])[1]))}
    ${row('zoom', ico('text', '#0a84ff'), 'Размер текста в чатах', esc((ZOOMS.find(a => a[0] === lookCfg().zoom) || ZOOMS[1])[1]))}
    ${row('compact', ico('rows', '#8e8e93'), 'Компактный список чатов', '', sw(lookCfg().compact))}
    <div class="st-h">Безопасность</div>
    ${row(L ? 'lock' : 'set', ico('lock', '#8e8e93'), 'Код-пароль', L ? 'Включён, автоблокировка ' + esc(autolockText(L.autolock)) : 'Выключен')}
    ${window.desktop?.protect ? row('protect', ico('shield', '#32d74b'), 'Скрывать окно от скриншотов и записи', 'На снимках экрана и при демонстрации окно будет пустым', sw(protectOn())) : ''}
    ${row('crypto', ico('key', '#ff9f0a'), 'Шифрование и ключи', S.cstate?.verified ? 'Этот вход подтверждён ✓' : 'Ключ восстановления, сеансы, резервная копия')}
    ${row('sessions', ico('monitor', '#0a84ff'), 'Мои сеансы', 'Устройства, где выполнен вход')}
    <div class="st-h">Звонки</div>
    ${row('calls', ico('phone', '#32d74b'), 'Проверка звонков', 'Проверить соединение и TURN')}
    <div class="st-h">Аккаунт</div>
    ${row('profile', ico('user', '#bf5af2'), 'Профиль', 'Имя и фото')}
    <div class="st-h">О приложении</div>
    ${row('about', ico('info', '#8e8e93'), 'Ласточка ' + esc(APP_VER || ''), 'Сборка от ' + esc(BUILD_AT ? new Date(BUILD_AT).toLocaleDateString('ru-RU') : '—') + (window.desktop?.versions ? ' · Electron ' + esc(window.desktop.versions.electron) : '') + (buildOld() ? ' · ⚠️ пора обновить' : '') + ' · нажмите, чтобы проверить обновления', '')}
    ${row('logout', ico('logout', '#ff453a'), '<span style="color:#e53935">Выйти из аккаунта</span>', '', '')}`;
  panel(html, v => settingsAct(v));
  $('#modal .dlg').classList.add('st-dlg');
  const m = $('#modal'), prev = m.onclick;
  m.onclick = e => { if (e.target === m) return closePanel(); prev(e); };
  hydrate($('#modal'));
}
document.addEventListener('keydown', e => { if (e.key === 'Escape' && $('#modal .st-dlg')) { e.stopPropagation(); closePanel(); } }, true);
async function settingsAct(v){
  const L = lockCfg(), n = notifCfg();
  if (v === 'close') return closePanel();
  if (v === 'about') { closePanel(); return checkUpdate(true); }
  if (v.startsWith('n-') && v !== 'n-test') {
    const k = v.slice(2);
    try { localStorage.setItem(LS_NOTIF, JSON.stringify({...n, [k]:!n[k]})); } catch {}
    return settingsDialog();
  }
  if (v === 'n-test') { sysNotify({title:'Ласточка', body:'Уведомления работают ✓', tag:'test'}); return; }
  if (v === 'protect') { setProtect(!protectOn()); return settingsDialog(); }
  if (v === 'compact') { setLook({compact:!lookCfg().compact}); return settingsDialog(); }
  if (['accent', 'wall', 'zoom'].includes(v)) { S.settingsNav = true; return lookDialog(v); }
  if (v === 'theme') { setTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark', true); return settingsDialog(); }
  closePanel();
  S.settingsNav = true;
  if (v === 'set') {
    const p = await askNewPass(); if (!p) return;
    const a = await askAutolock(300e3);
    await savePass(p, a ?? 300e3);
    toast('Код-пароль установлен. Заблокировать вручную — значок замка вверху или ⌘L / Ctrl+L');
    return settingsDialog();
  }
  if (v === 'lock') {
    const r = await modal({title:'Код-пароль', html:`<p>Включён, автоблокировка ${esc(autolockText(L.autolock))}.</p>`, buttons:[{label:'Изменить код', value:'change'}, {label:'Автоблокировка', value:'auto'}, {label:'Отключить код', value:'off', danger:true}, {label:'Готово'}]});
    if (r === 'change') {
      if (!(await verifyCurrent())) return;
      const p = await askNewPass(); if (!p) return;
      await savePass(p, L.autolock); toast('Код-пароль изменён');
    } else if (r === 'auto') {
      const a = await askAutolock(L.autolock); if (a == null) return;
      localStorage.setItem(LS_LOCK, JSON.stringify({...L, autolock:a})); toast('Автоблокировка ' + autolockText(a));
    } else if (r === 'off') {
      if (!(await verifyCurrent())) return;
      localStorage.removeItem(LS_LOCK); localStorage.removeItem(LS_LOCKFAIL); updateLockBtn(); toast('Код-пароль отключён');
    }
    return settingsDialog();
  }
  if (v === 'crypto') return cryptoDialog();
  if (v === 'calls') return callSettings();
  if (v === 'sessions') return sessionsDialog();
  if (v === 'profile') return profileDialog();
  if (v === 'logout') { S.settingsNav = false; return logout(); }
}

/* ---------- search ---------- */
const norm = s => String(s || '').toLowerCase().replace(/ё/g, 'е');
function evText(ev){
  if (!isMsg(ev) || ev.isRedacted() || ev.isDecryptionFailure() || ev.getType() === 'm.room.encrypted') return '';
  const c = ev.getContent() || {};
  return [stripReply(c.body), c.filename && c.filename !== c.body ? c.filename : ''].filter(Boolean).join(' ');
}
function searchRoom(room, q){
  const t = norm(q);
  if (!t) return [];
  return liveEvents(room).filter(ev => !isExpired(ev) && norm(evText(ev)).includes(t)).reverse();
}
function hl(text, q){
  const t = norm(q), s = String(text || ''), ns = norm(s);
  if (!t) return esc(s);
  let out = '', last = 0, i = ns.indexOf(t);
  const start = Math.max(0, i - 30);
  if (start > 0) { out = '…'; last = start; }
  while (i >= 0) { out += esc(s.slice(last, i)) + '<mark>' + esc(s.slice(i, i + t.length)) + '</mark>'; last = i + t.length; i = ns.indexOf(t, last); }
  return out + esc(s.slice(last));
}
function markTerm(root, q){
  const t = norm(q); if (!t) return;
  root.querySelectorAll('.text, .fn').forEach(el => {
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), nodes = [];
    while (w.nextNode()) nodes.push(w.currentNode);
    for (const n of nodes) {
      const s = n.nodeValue, ns = norm(s);
      let i = ns.indexOf(t); if (i < 0) continue;
      const frag = document.createDocumentFragment(); let last = 0;
      while (i >= 0) { frag.append(s.slice(last, i)); const m = document.createElement('mark'); m.textContent = s.slice(i, i + t.length); frag.append(m); last = i + t.length; i = ns.indexOf(t, last); }
      frag.append(s.slice(last)); n.replaceWith(frag);
    }
  });
}
function openFind(){
  const room = cur(); if (!room) return;
  S.find = S.find || {q:'', results:[], idx:-1};
  $('#sbar').hidden = false;
  const i = $('#sq'); i.value = S.find.q; i.focus(); i.select();
  if (S.find.q) renderFindResults(true);
}
function closeFind(){
  if (!S.find) return;
  S.find = null; $('#sbar').hidden = true; $('#sres').hidden = true;
  if (cur()) renderTimeline();
}
let findT;
function runFind(){
  const room = cur(); if (!room || !S.find) return;
  S.find.q = $('#sq').value.trim();
  S.find.results = S.find.q ? searchRoom(room, S.find.q) : [];
  S.find.idx = -1;
  renderFindResults(true);
  renderTimeline();
}
function renderFindResults(show){
  const f = S.find, room = cur(); if (!f || !room) return;
  const n = f.results.length;
  $('#scount').textContent = !f.q ? '' : n ? (f.idx >= 0 ? `${f.idx + 1} из ${n}` : `Найдено: ${n}`) : 'Нет совпадений';
  const res = $('#sres');
  if (!f.q || !show) { res.hidden = true; return; }
  const more = !uiOf(room.roomId).reachedStart;
  res.innerHTML = f.results.slice(0, 100).map((ev, i) => `<div class="sr${i === f.idx ? ' on' : ''}" data-i="${i}"><div class="sr1"><b>${esc(memberName(room, ev.getSender()))}</b><span>${esc(fmtDay(ev.getTs()))}, ${esc(fmtTime(ev.getTs()))}</span></div><div class="sr2">${hl(evText(ev), f.q)}</div></div>`).join('')
    + (n ? '' : `<div class="sr-empty">В загруженных сообщениях ничего нет${isEncrypted(room) ? '. Зашифрованные сообщения ищутся только на этом устройстве, сервер их прочитать не может.' : '.'}</div>`)
    + (more ? '<button class="sr-more" id="sr-more">Искать в более ранних сообщениях</button>' : '<div class="sr-empty">Просмотрена вся история чата</div>');
  res.hidden = false;
}
function findGo(i){
  const f = S.find; if (!f?.results.length) return;
  f.idx = (i + f.results.length) % f.results.length;
  renderFindResults(false);
  jumpTo(f.results[f.idx].getId());
}
async function findDeeper(){
  const room = cur(); if (!room || !S.find) return;
  const b = $('#sr-more'); if (b) { b.disabled = true; b.textContent = 'Загружаем историю…'; }
  for (let i = 0; i < 6 && !uiOf(room.roomId).reachedStart && S.current === room.roomId; i++) await older(room);
  if (S.current !== room.roomId || !S.find) return;
  S.find.results = searchRoom(room, S.find.q);
  renderFindResults(true); renderTimeline();
}
$('#find-btn').onclick = () => (S.find && !$('#sbar').hidden ? closeFind() : openFind());
$('#sclose').onclick = closeFind;
$('#sq').addEventListener('input', () => { clearTimeout(findT); findT = setTimeout(runFind, 180); });
$('#sq').addEventListener('focus', () => { if (S.find?.q) renderFindResults(true); });
$('#sq').addEventListener('keydown', e => {
  if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); if (!$('#sres').hidden) $('#sres').hidden = true; else closeFind(); }
  else if (e.key === 'Enter') { e.preventDefault(); findGo((S.find?.idx ?? -1) + (e.shiftKey ? -1 : 1)); }
});
$('#sup').onclick = () => findGo((S.find?.idx ?? -1) + 1);
$('#sdown').onclick = () => findGo((S.find?.idx ?? 1) - 1);
$('#scount').onclick = () => { if ($('#sres').hidden) renderFindResults(true); else $('#sres').hidden = true; };
// выпадающий список результатов — под строкой поиска, а не поверх шапки
$('#sbar').append($('#sres'));
// клик мимо поиска прячет список результатов
document.addEventListener('mousedown', e => { if (!$('#sres').hidden && !e.target.closest('#sbar')) $('#sres').hidden = true; });
// крестик в поиске по чатам
{
  const inp = $('#search'), x = document.createElement('button');
  x.id = 'search-x'; x.className = 'search-x'; x.type = 'button'; x.hidden = true; x.setAttribute('aria-label', 'Очистить');
  x.innerHTML = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>';
  inp.after(x);
  const sync = () => { x.hidden = !inp.value; };
  inp.addEventListener('input', sync);
  x.addEventListener('mousedown', e => e.preventDefault());
  x.onclick = () => { inp.value = ''; S.search = ''; sync(); renderList(); inp.focus(); };
  inp.addEventListener('keydown', e => { if (e.key === 'Escape' && inp.value) { e.stopPropagation(); x.click(); } });
}
$('#sres').addEventListener('click', e => {
  if (e.target.closest('#sr-more')) return findDeeper();
  const r = e.target.closest('[data-i]'); if (r) findGo(+r.dataset.i);
});
function globalHits(q){
  if (norm(q).length < 2) return [];
  const hits = [];
  for (const r of S.client.getRooms()) {
    if (membership(r) !== 'join' || r.isSpaceRoom()) continue;
    for (const ev of searchRoom(r, q).slice(0, 5)) hits.push([r, ev]);
  }
  return hits.sort((a, b) => b[1].getTs() - a[1].getTs()).slice(0, 40);
}
function hitsHTML(q){
  const hits = globalHits(q);
  if (!hits.length) return '';
  return `<div class="list-h">Сообщения</div>` + hits.map(([r, ev]) => `<div class="chat hit" data-room="${esc(r.roomId)}" data-ev="${esc(ev.getId())}" role="button" tabindex="0">${roomAvatar(r, 46)}<div class="ci"><div class="r1"><span class="t"><span style="overflow:hidden;text-overflow:ellipsis">${esc(roomName(r))}</span></span><span class="time">${esc(listTime(ev.getTs()))}</span></div><div class="r2"><span class="p"><span class="who">${ev.getSender() === S.userId ? 'Вы' : esc(memberName(r, ev.getSender()))}: </span>${hl(evText(ev), q)}</span></div></div></div>`).join('')
    + '<div class="list-note">Поиск идёт по загруженным сообщениям на этом устройстве — зашифрованную переписку сервер не видит. Для поиска по всей истории откройте чат и нажмите 🔍.</div>';
}

/* ---------- pinned messages ---------- */
const pinCache = new Map(), pinFetching = new Set();
function pinnedIds(room){
  const p = room.currentState.getStateEvents('m.room.pinned_events', '')?.getContent()?.pinned;
  return Array.isArray(p) ? p.filter(x => typeof x === 'string') : [];
}
const canPin = room => membership(room) === 'join' && room.currentState.maySendStateEvent('m.room.pinned_events', S.userId);
const inLive = (room, id) => liveEvents(room).some(e => e.getId() === id);
function pinnedEvent(room, id){ return room.findEventById(id) || pinCache.get(id) || null; }
async function fetchPinned(room, id){
  if (pinCache.has(id) || pinFetching.has(id)) return;
  pinFetching.add(id);
  try {
    const raw = await S.client.fetchRoomEvent(room.roomId, id);
    const ev = S.client.getEventMapper()(raw);
    await S.client.decryptEventIfNeeded?.(ev);
    pinCache.set(id, ev);
  } catch { pinCache.set(id, null); }
  finally { pinFetching.delete(id); scheduleFor(room.roomId); }
}
function renderPinbar(){
  const room = cur(), bar = $('#pinbar');
  const ids = room ? pinnedIds(room) : [];
  if (!ids.length) { bar.hidden = true; bar.innerHTML = ''; return; }
  let idx = S.pinIdx.get(room.roomId) ?? ids.length - 1;
  if (idx >= ids.length || idx < 0) idx = ids.length - 1;
  const id = ids[idx], ev = pinnedEvent(room, id);
  if (!ev && !pinCache.has(id)) fetchPinned(room, id);
  const text = ev ? (isMsg(ev) ? snippet(room, ev) : 'Сообщение') : pinCache.has(id) ? 'Сообщение недоступно' : 'Загрузка…';
  const seg = ids.length > 1 ? `<div class="pin-seg">${ids.map((_, i) => `<i class="${i === idx ? 'on' : ''}"></i>`).join('')}</div>` : '<div class="pin-seg"><i class="on"></i></div>';
  bar.innerHTML = `${seg}<button class="pin-body" data-pin="${esc(id)}"><b>${ids.length > 1 ? `Закреплённое сообщение #${idx + 1}` : 'Закреплённое сообщение'}</b><span>${esc(text)}</span></button>${canPin(room) ? `<button class="icon-btn" data-unpin="${esc(id)}" aria-label="Открепить" title="Открепить">${I.close}</button>` : ''}`;
  bar.hidden = false;
}
async function jumpToEvent(room, id){
  if (inLive(room, id)) return jumpTo(id);
  toast('Ищем сообщение в истории…', true);
  for (let i = 0; i < 25 && !uiOf(room.roomId).reachedStart && S.current === room.roomId; i++) {
    await older(room);
    if (inLive(room, id)) { $('#toast').hidden = true; renderTimeline(); return jumpTo(id); }
  }
  $('#toast').hidden = true;
  const ev = pinnedEvent(room, id);
  if (ev) modal({title:'Сообщение', html:`<div class="info-row"><small>${esc(memberName(room, ev.getSender()))}, ${esc(fmtDay(ev.getTs()))} ${esc(fmtTime(ev.getTs()))}</small>${esc(isMsg(ev) ? (evText(ev) || snippet(room, ev)) : '')}</div>`, buttons:[{label:'Закрыть', value:true}]});
  else toast('Сообщение не найдено — возможно, оно удалено');
}
async function togglePin(room, id){
  const ids = pinnedIds(room);
  const pinned = ids.includes(id) ? ids.filter(x => x !== id) : [...ids, id];
  try {
    await S.client.sendStateEvent(room.roomId, 'm.room.pinned_events', {pinned}, '');
    S.pinIdx.delete(room.roomId);
    toast(ids.includes(id) ? 'Сообщение откреплено' : 'Сообщение закреплено');
  } catch (e) { toast('Не удалось: ' + e.message); }
}
$('#pinbar').addEventListener('click', async e => {
  const room = cur(); if (!room) return;
  const un = e.target.closest('[data-unpin]');
  if (un) {
    const ok = await modal({title:'Открепить сообщение?', html:'<p>Сообщение открепится у всех участников чата.</p>', buttons:[{label:'Отмена'}, {label:'Открепить', value:true, danger:true}]});
    if (ok) togglePin(room, un.dataset.unpin);
    return;
  }
  const b = e.target.closest('[data-pin]'); if (!b) return;
  const ids = pinnedIds(room);
  const idx = S.pinIdx.get(room.roomId) ?? ids.length - 1;
  S.pinIdx.set(room.roomId, idx - 1 < 0 ? ids.length - 1 : idx - 1);
  jumpToEvent(room, b.dataset.pin);
  renderPinbar();
});

/* ---------- forwarding ---------- */
function forwardContent(room, ev){
  const type = ev.getType();
  const c = JSON.parse(JSON.stringify(ev.getContent() || {}));
  delete c['m.relates_to']; delete c['m.new_content']; delete c.format; delete c.formatted_body; delete c[EXP_KEY];
  if (typeof c.body === 'string') c.body = stripReply(c.body);
  const orig = c['mxtg.forwarded'];
  c['mxtg.forwarded'] = orig || {sender:ev.getSender(), name:memberName(room, ev.getSender()), ts:ev.getTs()};
  return {type, content:c};
}
function forwardDialog(room, ev, payload){
  const list = S.client.getRooms().filter(r => canSend(r) && !r.isSpaceRoom()).map(r => [r, sortTs(r)]).sort((a, b) => b[1] - a[1]).map(x => x[0]);
  const sel = new Set();
  const draw = (q = '') => {
    const t = norm(q);
    const items = list.filter(r => !t || norm(roomName(r)).includes(t));
    return items.map(r => `<label class="fw-item"><input type="checkbox" data-fw="${esc(r.roomId)}"${sel.has(r.roomId) ? ' checked' : ''}>${roomAvatar(r, 40)}<span class="fw-n">${isEncrypted(r) ? I.lock : ''}${esc(roomName(r))}</span></label>`).join('') || '<p>Ничего не найдено</p>';
  };
  panel(`<h3>${payload ? 'Переслать ссылку' : 'Переслать сообщение'}</h3><input class="field" id="fw-q" placeholder="Поиск чата" autocomplete="off"><div class="fw-list" id="fw-list">${draw()}</div><div class="dlg-btns"><button class="btn-flat" data-v="cancel">Отмена</button><button class="btn-flat" data-v="send" id="fw-send" disabled>Переслать</button></div>`, async v => {
    if (v === 'cancel') return closePanel();
    if (v === 'send' && sel.size) { const targets = [...sel].map(id => S.client.getRoom(id)).filter(Boolean); closePanel(); doForward(room, ev, targets, payload); }
  });
  hydrate($('#modal'));
  const q = $('#fw-q');
  q.oninput = () => { $('#fw-list').innerHTML = draw(q.value); hydrate($('#fw-list')); };
  q.onkeydown = e => { if (e.key === 'Escape') { e.stopPropagation(); closePanel(); } };
  $('#fw-list').onchange = e => {
    const cb = e.target.closest('[data-fw]'); if (!cb) return;
    if (cb.checked) sel.add(cb.dataset.fw); else sel.delete(cb.dataset.fw);
    const b = $('#fw-send'); b.disabled = !sel.size; b.textContent = sel.size > 1 ? `Переслать (${sel.size})` : 'Переслать';
  };
  q.focus();
}
async function doForward(room, ev, targets, payload){
  const {type, content} = payload || forwardContent(room, ev);
  if (content.file && targets.some(r => !isEncrypted(r))) {
    const ok = await modal({title:'Переслать в чат без шифрования?', html:'<p>Файл из зашифрованного чата станет доступен серверу, если переслать его в чат без шифрования.</p>', buttons:[{label:'Отмена'}, {label:'Всё равно переслать', value:true}]});
    if (!ok) return;
  }
  let n = 0;
  for (const r of targets) {
    try { await S.client.sendEvent(r.roomId, type, withTTL(r, JSON.parse(JSON.stringify(content)))); n++; }
    catch (e) { toast(`Не удалось переслать в «${roomName(r)}»: ${e.message}`); }
  }
  if (n) toast(n === 1 ? `Переслано в «${roomName(targets.find(Boolean))}»` : `Переслано в ${plural(n, ['чат', 'чата', 'чатов'])}`);
}

/* ---------- floating date ---------- */
let fdT;
function updateFloatDate(){
  const box = $('#messages'), fd = $('#fdate');
  const rows = box.querySelectorAll('[data-ts]');
  if (!rows.length || box.scrollTop < 10) { fd.classList.remove('show'); return; }
  const top = box.scrollTop + 6;
  let lo = 0, hi = rows.length - 1, ans = rows.length - 1;
  while (lo <= hi) { const mid = (lo + hi) >> 1, r = rows[mid]; if (r.offsetTop + r.offsetHeight > top) { ans = mid; hi = mid - 1; } else lo = mid + 1; }
  fd.firstElementChild.textContent = fmtDay(+rows[ans].dataset.ts);
  fd.style.top = (box.offsetTop + 8) + 'px';
  fd.classList.add('show');
  clearTimeout(fdT); fdT = setTimeout(() => fd.classList.remove('show'), 1300);
}

/* ---------- account: profile, password, sessions, key export ---------- */
async function withAuth(fn, why){
  try { return await fn(undefined); }
  catch (e) {
    const session = e.data?.session;
    if (e.httpStatus !== 401 || !session) throw e;
    const pw = await modal({title:'Подтвердите паролем', html:`<p>${esc(why)}</p>`, input:'Пароль от аккаунта', inputType:'password', buttons:[{label:'Отмена'}, {label:'Подтвердить', value:true}]});
    if (!pw) throw new Error('Отменено');
    try { return await fn({type:'m.login.password', identifier:{type:'m.id.user', user:S.userId}, password:pw, session}); }
    catch (e2) { if (e2.httpStatus === 401) throw new Error('Неверный пароль'); throw e2; }
  }
}
async function refreshMe(){
  try { const p = await S.client.getProfileInfo(S.userId); S.me = {name:p.displayname || '', avatar:p.avatar_url || ''}; } catch {}
}
async function squareImage(file, size = 512){
  const bmp = await createImageBitmap(file);
  const s = Math.min(bmp.width, bmp.height);
  const cv = document.createElement('canvas'); cv.width = cv.height = Math.min(size, s);
  cv.getContext('2d').drawImage(bmp, (bmp.width - s) / 2, (bmp.height - s) / 2, s, s, 0, 0, cv.width, cv.height);
  bmp.close?.();
  return await new Promise(r => cv.toBlob(r, 'image/jpeg', 0.9));
}
function pickFile(accept){
  return new Promise(res => {
    const f = document.createElement('input'); f.type = 'file'; f.accept = accept;
    f.onchange = () => res(f.files[0] || null);
    f.click();
  });
}
async function profileDialog(){
  await refreshMe();
  const name = S.me.name || localpart(S.userId);
  const html = `<div class="info-top">${avatarHTML(S.me.avatar, S.userId, name, 96)}<div class="nm">${esc(name)}</div><div style="color:var(--muted);font-size:14px">${esc(S.userId)}</div></div>
    <p style="font-size:13px">Имя и фото видят все, с кем вы переписываетесь. Фото профиля хранится на сервере без шифрования, как и в Element.</p>`;
  const buttons = [{label:'Изменить фото', value:'photo'}];
  if (S.me.avatar) buttons.push({label:'Удалить фото', value:'nophoto', danger:true});
  buttons.push({label:'Изменить имя', value:'name'}, {label:'Сменить пароль', value:'password'}, {label:'Закрыть'});
  const p = modal({title:'Мой профиль', html, buttons});
  hydrate($('#modal'));
  const v = await p;
  if (v === 'photo') {
    const file = await pickFile('image/png,image/jpeg,image/webp,image/gif');
    if (!file) return;
    toast('Загружаем фото…', true);
    try {
      const blob = await squareImage(file);
      const r = await S.client.uploadContent(blob, {name:'avatar.jpg', type:'image/jpeg'});
      await S.client.setAvatarUrl(r.content_uri);
      mediaReady.set(r.content_uri + '|96', URL.createObjectURL(blob));
      await refreshMe(); toast('Фото профиля обновлено'); schedule(); profileDialog();
    } catch (e) { toast('Не удалось обновить фото: ' + e.message); }
  } else if (v === 'nophoto') {
    try { await S.client.setAvatarUrl(''); await refreshMe(); toast('Фото удалено'); schedule(); profileDialog(); }
    catch (e) { toast('Не удалось: ' + e.message); }
  } else if (v === 'name') {
    const n = await modal({title:'Отображаемое имя', html:'<p>Так вас будут видеть в чатах.</p>', input:'Имя', value:S.me.name, buttons:[{label:'Отмена'}, {label:'Сохранить', value:true}]});
    if (!n) return;
    if (n.length > 100) { toast('Слишком длинное имя'); return; }
    toast('Сохраняем…', true);
    try { await S.client.setDisplayName(n); await refreshMe(); toast('Имя изменено'); schedule(); profileDialog(); }
    catch (e) { toast('Не удалось изменить имя: ' + e.message); }
  } else if (v === 'password') passwordDialog();
}
function passwordDialog(){
  panel(`<h3>Сменить пароль</h3>
    <p>Ключи шифрования при смене пароля сохраняются. Если завершить другие сеансы, на тех устройствах придётся войти заново.</p>
    <input class="field" id="pw-old" type="password" placeholder="Текущий пароль" autocomplete="current-password">
    <input class="field" id="pw-new" type="password" placeholder="Новый пароль (не короче 8 символов)" autocomplete="new-password">
    <input class="field" id="pw-new2" type="password" placeholder="Новый пароль ещё раз" autocomplete="new-password">
    <label class="chk-line"><input type="checkbox" id="pw-out"> Завершить все другие сеансы</label>
    <div class="err" id="pw-err" hidden></div>
    <div class="dlg-btns"><button class="btn-flat" data-v="cancel">Отмена</button><button class="btn-flat" data-v="ok" id="pw-ok">Сменить пароль</button></div>`, async v => {
    if (v === 'cancel') return closePanel();
    if (v !== 'ok') return;
    const old = $('#pw-old').value, n1 = $('#pw-new').value, n2 = $('#pw-new2').value, out = $('#pw-out').checked;
    const err = m => { const e = $('#pw-err'); e.textContent = m; e.hidden = false; };
    if (!old) return err('Введите текущий пароль');
    if (n1.length < 8) return err('Новый пароль должен быть не короче 8 символов');
    if (n1 !== n2) return err('Новые пароли не совпадают');
    if (n1 === old) return err('Новый пароль совпадает с текущим');
    const btn = $('#pw-ok'); btn.disabled = true; btn.textContent = 'Меняем…';
    const auth = {type:'m.login.password', identifier:{type:'m.id.user', user:S.userId}, password:old};
    try {
      try { await S.client.setPassword(auth, n1, out); }
      catch (e) {
        if (e.httpStatus === 401 && e.data?.session && !e.errcode) await S.client.setPassword({...auth, session:e.data.session}, n1, out);
        else throw e;
      }
      closePanel();
      toast('Пароль изменён' + (out ? '. Другие сеансы завершены' : ''));
    } catch (e) {
      btn.disabled = false; btn.textContent = 'Сменить пароль';
      err(e.errcode === 'M_FORBIDDEN' || e.httpStatus === 401 ? 'Неверный текущий пароль'
        : e.errcode === 'M_WEAK_PASSWORD' ? 'Слишком простой пароль' + (e.message ? ': ' + e.message : '')
        : e.errcode === 'M_UNRECOGNIZED' || e.httpStatus === 404 ? 'Сервер не разрешает менять пароль из клиента' : e.message);
    }
  }, {back:true});
  $('#pw-old').focus();
}
async function sessionsDialog(){
  toast('Загружаем сеансы…', true);
  let devs;
  try { devs = (await S.client.getDevices()).devices || []; }
  catch (e) { toast('Не удалось получить список сеансов: ' + e.message); return; }
  const c = crypto_(), st = new Map();
  await Promise.all(devs.map(d => c?.getDeviceVerificationStatus(S.userId, d.device_id).then(s => st.set(d.device_id, !!s?.crossSigningVerified)).catch(() => {})));
  $('#toast').hidden = true;
  devs.sort((a, b) => (b.device_id === S.deviceId) - (a.device_id === S.deviceId) || (b.last_seen_ts || 0) - (a.last_seen_ts || 0));
  const others = devs.filter(d => d.device_id !== S.deviceId);
  const row = d => {
    const me = d.device_id === S.deviceId, ok = st.get(d.device_id);
    const seen = d.last_seen_ts ? 'Активность: ' + new Date(d.last_seen_ts).toLocaleString('ru-RU') : 'Нет данных об активности';
    return `<div class="sess"><div class="sess-ic" title="${ok ? 'Подтверждён' : 'Не подтверждён'}">${ok ? '✅' : '⚠️'}</div><div class="sess-b">
      <b>${esc(d.display_name || 'Без названия')}</b>${me ? ' <span class="tag">это устройство</span>' : ''}
      <small>${esc(d.device_id)} · ${ok ? 'подтверждён' : 'не подтверждён'}</small>
      <small>${esc(seen)}${d.last_seen_ip ? ' · IP ' + esc(d.last_seen_ip) : ''}</small>
      <div class="sess-a"><button class="btn-flat" data-v="rename:${esc(d.device_id)}">Переименовать</button>${!me && !ok && S.cstate.verified ? `<button class="btn-flat" data-v="verify:${esc(d.device_id)}">Подтвердить</button>` : ''}${!me ? `<button class="btn-flat danger" data-v="out:${esc(d.device_id)}">Завершить</button>` : ''}</div>
    </div></div>`;
  };
  panel(`<h3>Мои сеансы</h3><p>Все устройства, где выполнен вход в аккаунт. Если какой-то сеанс вы не узнаёте, завершите его и смените пароль.</p>
    <div class="sess-list">${devs.map(row).join('')}</div>
    <div class="dlg-btns">${others.length > 1 ? `<button class="btn-flat danger" data-v="outall">Завершить все другие (${others.length})</button>` : ''}</div>`, async v => {
    const i = v.indexOf(':'), act = i < 0 ? v : v.slice(0, i), id = i < 0 ? '' : v.slice(i + 1);
    if (act === 'close') return closePanel();
    closePanel();
    if (act === 'rename') {
      const d = devs.find(x => x.device_id === id);
      const n = await modal({title:'Название сеанса', html:'<p>Название видно только вам — в списке сеансов здесь и в Element.</p>', input:'Название', value:d?.display_name || '', buttons:[{label:'Отмена'}, {label:'Сохранить', value:true}]});
      if (n) { try { await S.client.setDeviceDetails(id, {display_name:n}); toast('Сеанс переименован'); } catch (e) { toast('Не удалось: ' + e.message); } }
      return sessionsDialog();
    }
    if (act === 'verify') {
      try { verifyFlow(await c.requestDeviceVerification(S.userId, id)); } catch (e) { toast('Не удалось отправить запрос: ' + (e.message || e)); }
      return;
    }
    if (act === 'out' || act === 'outall') {
      const ids = act === 'out' ? [id] : others.map(d => d.device_id);
      const ok = await modal({title:act === 'out' ? 'Завершить сеанс?' : `Завершить ${plural(ids.length, ['сеанс', 'сеанса', 'сеансов'])}?`, html:'<p>На этих устройствах произойдёт выход из аккаунта. Если на них не сохранён ключ восстановления, их ключи шифрования пропадут.</p>', buttons:[{label:'Отмена'}, {label:'Завершить', value:true, danger:true}]});
      if (!ok) return sessionsDialog();
      try {
        await withAuth(auth => S.client.deleteMultipleDevices(ids, auth), 'Чтобы завершить сеансы, введите пароль от аккаунта.');
        toast(ids.length === 1 ? 'Сеанс завершён' : 'Сеансы завершены');
      } catch (e) { if (e.message !== 'Отменено') toast('Не удалось: ' + e.message); }
      return sessionsDialog();
    }
  }, {back:true, cls:'st-dlg'});
}
function saveText(text, name){
  const u = URL.createObjectURL(new Blob([text], {type:'text/plain'}));
  const a = document.createElement('a'); a.href = u; a.download = name; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(u), 60000);
}
async function exportKeys(){
  const c = crypto_(); if (!c) { toast('Шифрование не запущено'); return; }
  const p1 = await modal({title:'Экспорт ключей', html:'<p>В файл попадут ключи для расшифровки всей вашей переписки. Он защищается паролем, который вы зададите. Файл можно импортировать сюда или в Element (Настройки → Безопасность → Импорт ключей).</p><p>Храните файл и пароль отдельно и в надёжном месте.</p>', input:'Пароль для файла (не короче 8 символов)', inputType:'password', buttons:[{label:'Отмена'}, {label:'Далее', value:true}]});
  if (!p1) return;
  if (p1.length < 8) { toast('Пароль для файла должен быть не короче 8 символов'); return; }
  const p2 = await modal({title:'Повторите пароль', input:'Пароль для файла ещё раз', inputType:'password', buttons:[{label:'Отмена'}, {label:'Экспортировать', value:true}]});
  if (p2 == null) return;
  if (p1 !== p2) { toast('Пароли не совпадают'); return; }
  toast('Экспортируем ключи…', true);
  try {
    const json = c.exportRoomKeysAsJson ? await c.exportRoomKeysAsJson() : JSON.stringify(await c.exportRoomKeys());
    const n = JSON.parse(json).length;
    const file = await encryptKeyExport(json, p1);
    saveText(file, `matrix-keys-${new Date().toISOString().slice(0, 10)}.txt`);
    toast(`Экспортировано ключей: ${n}` + (IS_ELECTRON ? '. Файл сохранён в «Загрузки»' : ''));
  } catch (e) { toast('Не удалось экспортировать: ' + e.message); }
}
async function importKeys(){
  const c = crypto_(); if (!c) { toast('Шифрование не запущено'); return; }
  const file = await pickFile('.txt,text/plain');
  if (!file) return;
  const text = await file.text();
  if (!/BEGIN MEGOLM SESSION DATA/.test(text)) { toast('Это не файл ключей Matrix'); return; }
  const pass = await modal({title:'Импорт ключей', html:`<p>Файл «${esc(file.name)}». Введите пароль, который задавали при экспорте.</p>`, input:'Пароль файла', inputType:'password', buttons:[{label:'Отмена'}, {label:'Импортировать', value:true}]});
  if (!pass) return;
  toast('Расшифровываем файл…', true);
  try {
    const json = await decryptKeyExport(text, pass);
    const total = JSON.parse(json).length;
    const progressCallback = p => { if (p?.total) toast(`Импорт ключей… ${p.successes || 0} из ${p.total}`, true); };
    if (c.importRoomKeysAsJson) await c.importRoomKeysAsJson(json, {progressCallback});
    else await c.importRoomKeys(JSON.parse(json), {progressCallback});
    toast(`Импортировано ключей: ${total}. Старые сообщения расшифруются автоматически`);
    schedule();
  } catch (e) { toast(e.message); }
}

/* ---------- серверы для звонков и диагностика ---------- */
// Без STUN/TURN устройство знает только свои внутренние адреса, и через интернет
// звонок «висит на соединении». TURN вашего Synapse — основной путь; публичный STUN —
// резервный, только с согласия (STUN-сервер узнаёт ваш внешний IP, но не звук/видео).
// Маршруты для звонков — как в Element Classic: TURN, который выдаёт сервер Matrix (+ внешний TURN из calls.config.js, если задан);
// если сервер TURN не выдал — резервный STUN matrix.org (встроен в matrix-js-sdk).
const XTURN = {servers:[], label:"", fetchedAt:0};
async function loadExternalTurn(){
  const cfg = CALLS_CFG || {};
  try {
    if (cfg.metered?.app && cfg.metered?.apiKey) {
      const r = await fetch(`https://${encodeURIComponent(cfg.metered.app)}.metered.live/api/v1/turn/credentials?apiKey=${encodeURIComponent(cfg.metered.apiKey)}`);
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const list = await r.json();
      XTURN.servers = (Array.isArray(list) ? list : []).filter(x => x && (x.urls || x.url));
      XTURN.label = 'Metered';
    } else if (Array.isArray(cfg.turn) && cfg.turn.length) {
      XTURN.servers = cfg.turn; XTURN.label = 'внешний TURN';
    }
    XTURN.fetchedAt = Date.now();
  } catch (e) { console.warn('external TURN', e); }
}
// Внутри сети сервера внешний адрес ретранслятора недоступен (разворот через шлюз не работает),
// поэтому дополнительно даём тот же TURN по внутреннему IP. Снаружи этот адрес просто не ответит,
// и звонок пойдёт через внешний — работают оба варианта. Логин TURN от адреса не зависит.
function lanTurnHost(){
  const map = CALLS_CFG?.lanTurnHosts || {}, dom = S.userId ? serverName() : '';
  return String(map[dom] || '').trim();
}
function lanTurn(list){
  const ip = lanTurnHost();
  if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) return [];
  const out = [];
  for (const srv of list || []) {
    const urls = [...new Set([].concat(srv.urls || srv.url || []).map(u => {
      const m = /^turns?:(?:\[[^\]]+\]|[^:?]+)(:\d+)?(\?transport=(udp|tcp))?/i.exec(u); if (!m) return null;
      const tls = /^turns:/i.test(u);
      return `turn:${ip}:${tls ? 3478 : (m[1] ? m[1].slice(1) : 3478)}?transport=${tls ? 'tcp' : (m[3] || 'udp').toLowerCase()}`;
    }).filter(Boolean))];
    if (urls.length) out.push({urls, username:srv.username, credential:srv.credential});
  }
  return out;
}
// Посредник для звонков: WebRTC подключается к TURN на 127.0.0.1, а приложение пересылает
// пакеты на сервер звонков (через VPN и т.п. модуль звонков сам на macOS не пробивается).
const TPROXY = {ports:null, target:'', busy:false};
function proxyTurn(list){
  const p = TPROXY.ports, s = (list || []).find(x => isTurn([x]));
  if (!p || !s) return [];
  const addrs = [...new Set(p.addrs?.length ? p.addrs : ['127.0.0.1'])];
  return [{urls:addrs.flatMap(a => [`turn:${a}:${p.udp}?transport=udp`, `turn:${a}:${p.tcp}?transport=tcp`]), username:s.username, credential:s.credential}];
}
async function setupTurnProxy(){
  const D = window.desktop;
  if (!D?.turnProxy || !D?.probe || TPROXY.busy) return;
  const srv = S.serverTurn?.() || [];
  if (!isTurn(srv)) return;
  TPROXY.busy = true;
  try {
    const cands = [];
    const lan = lanTurnHost();
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(lan)) cands.push({host:lan, port:3478});
    for (const x of srv) for (const u of [].concat(x.urls || x.url || [])) {
      const m = /^turn:([^?:]+)(?::(\d+))?/i.exec(u);
      if (m && !cands.some(c => c.host === m[1])) cands.push({host:m[1], port:+(m[2] || 3478)});
    }
    const res = await D.probe(cands.flatMap(c => [{...c, proto:'udp'}, {...c, proto:'tcp'}]));
    const ok = cands.find(c => res.some(r => r.ok && r.host === c.host));
    if (!ok) return;
    const cred = srv.find(x => isTurn([x])) || {};
    TPROXY.ports = await D.turnProxy(ok.host, ok.port, cred.username || '', cred.credential || '');
    TPROXY.target = ok.host;
  } catch (e) { console.warn('turn proxy', e); }
  finally { TPROXY.busy = false; }
}
// Нет микрофона (частый случай на RDP) — не обрываем звонок, а подставляем «тишину»:
// вы слышите собеседника, он вас нет. Камера недоступна — звоним без видео.
function silentStream(video){
  const ctx = new AudioContext(), dst = ctx.createMediaStreamDestination();
  const osc = ctx.createOscillator(), g = ctx.createGain(); g.gain.value = 0; osc.connect(g).connect(dst); osc.start();
  const tracks = [...dst.stream.getAudioTracks()];
  if (video) { const cv = Object.assign(document.createElement('canvas'), {width:320, height:240}); cv.getContext('2d').fillRect(0, 0, 320, 240); tracks.push(...cv.captureStream(1).getVideoTracks()); }
  return new MediaStream(tracks);
}
function patchMedia(client){
  const mh = client.getMediaHandler?.(); if (!mh || mh.__lastochka) return;
  mh.__lastochka = true;
  const orig = mh.getUserMediaStream.bind(mh);
  mh.getUserMediaStream = async (audio, video, ...rest) => {
    try { return await orig(audio, video, ...rest); }
    catch (e) {
      if (video) { try { const st = await orig(audio, false, ...rest); toast('Камера недоступна — звонок без видео'); return st; } catch {} }
      console.warn('getUserMedia', e);
      toast('Микрофон не найден — вы будете слышать собеседника, но он вас нет. На RDP включите «Удалённый звук → Запись с этого компьютера».');
      return silentStream(false);
    }
  };
}
function patchTurnServers(client){
  if (client.__lastochkaTurn) return;
  const orig = client.getTurnServers.bind(client);
  S.serverTurn = () => orig() || [];
  client.getTurnServers = () => { const srv = S.serverTurn(); const extra = [...proxyTurn(srv), ...lanTurn(srv), ...XTURN.servers]; return extra.length ? [...srv, ...extra] : srv; };
  client.__lastochkaTurn = true;
  loadExternalTurn();
  setInterval(loadExternalTurn, 6 * 3600e3);
  // пока сервер не выдал TURN — пробуем чаще, потом раз в 2 минуты (VPN включили/выключили)
  let n = 0;
  const tick = () => { setupTurnProxy(); setTimeout(tick, TPROXY.ports || ++n > 24 ? 120e3 : 5e3); };
  setTimeout(tick, 3e3);
  window.addEventListener('online', () => setTimeout(setupTurnProxy, 2e3));
}
const isTurn = list => (list || []).some(s => [].concat(s.urls || s.url || []).some(u => /^turns?:/i.test(u)));
const hasServerTurn = () => isTurn(S.serverTurn?.());
const hasAnyTurn = () => hasServerTurn() || isTurn(XTURN.servers);
async function gatherTypes(iceServers, ms = 7000){
  const types = new Set();
  const pc = new RTCPeerConnection({iceServers});
  try {
    pc.createDataChannel('probe');
    S.iceHosts = new Set();
    pc.onicecandidate = e => {
      const c = e.candidate?.candidate || '', m = / typ (\w+)/.exec(c); if (m) types.add(m[1]);
      const a = /^candidate:\S+ \d+ \w+ \d+ (\S+) \d+ typ host/.exec(c); if (a) S.iceHosts.add(a[1]);
    };
    await pc.setLocalDescription(await pc.createOffer());
    await new Promise(r => {
      const t = setTimeout(r, ms);
      pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === 'complete') { clearTimeout(t); r(); } };
    });
  } finally { pc.close(); }
  return types;
}
const isMac = /Mac/i.test(navigator.platform || navigator.userAgent);
async function testTurnUri(server, url, ms = 12000){
  const res = {url, relay:false, err:''};
  const pc = new RTCPeerConnection({iceServers:[{urls:[url], username:server.username, credential:server.credential}], iceTransportPolicy:'relay'});
  try {
    pc.createDataChannel('probe');
    pc.onicecandidate = e => { if (/ typ relay/.test(e.candidate?.candidate || '')) res.relay = true; };
    res.errs = [];
    pc.onicecandidateerror = e => {
      const t = `${e.errorCode || ''} ${e.errorText || ''}`.trim();
      // 701 «Address not associated…» приходит от «чужих» интерфейсов (VPN, IPv6) — не главное, если есть другая ошибка
      if (t && !res.errs.includes(t)) res.errs.push(t);
      res.err = res.errs.find(x => !/not associated/i.test(x)) || res.errs[0];
    };
    res.t0 = Date.now();
    await pc.setLocalDescription(await pc.createOffer());
    await new Promise(r => {
      const t = setTimeout(r, ms);
      pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === 'complete') { clearTimeout(t); r(); } };
    });
  } catch (e) { res.err = e.message; } finally { pc.close(); }
  res.ms = Date.now() - res.t0;
  return res;
}
const turnErrText = (err, t = {}) => !err && t.ms >= 11000 ? 'нет ответа за 12 с — до сервера не доходят пакеты'
  : !err ? 'сервер ответил, но ретранслятор не выдан'
  : /not associated/i.test(err) ? `нет ответа (${err})`
  : /^401/.test(err) ? `сервер отклонил логин TURN (${err}) — не совпадает turn_shared_secret в Synapse и coturn или сбито время на сервере`
  : /^70[01]/.test(err) ? `нет ответа (${err})`
  : !err ? 'ретранслятор не выдан, ошибок нет — coturn ответил, но не выделил адрес (проверьте relay-ip / external-ip в turnserver.conf)'
  : err;
async function callSettings(){
  toast('Проверяем звонки…', true);
  if (!XTURN.fetchedAt) await loadExternalTurn();
  let types = new Set(), err = '';
  const ice = S.client.getTurnServers().length ? S.client.getTurnServers() : (S.client.isFallbackICEServerAllowed?.() ? [{urls:['stun:turn.matrix.org']}] : []);
  try { types = await gatherTypes(ice); } catch (e) { err = e.message; }
  const turnTests = [];
  await setupTurnProxy();
  const st0 = await window.desktop?.turnStats?.(true).catch(() => null);
  for (const srv of [...proxyTurn(S.serverTurn()), ...S.serverTurn(), ...lanTurn(S.serverTurn()), ...XTURN.servers]) {
    for (const u of [].concat(srv.urls || srv.url || [])) if (/^turns?:/i.test(u)) turnTests.push(testTurnUri(srv, u));
  }
  for (let i = 0; i < turnTests.length; i++) turnTests[i] = await turnTests[i];
  const st1 = await window.desktop?.turnStats?.().catch(() => null);
  // простые STUN-запросы (без логина TURN): доходят ли вообще пакеты модуля звонков
  const stunTargets = ['stun:stun.l.google.com:19302'];
  const lanH = lanTurnHost(); if (lanH) stunTargets.push(`stun:${lanH}:3478`);
  for (const x of S.serverTurn()) for (const u of [].concat(x.urls || x.url || [])) { const m = /^turn:([^?:]+)(?::(\d+))?/i.exec(u); if (m && !stunTargets.includes(`stun:${m[1]}:${m[2] || 3478}`)) stunTargets.push(`stun:${m[1]}:${m[2] || 3478}`); }
  const stunRes = await Promise.all(stunTargets.map(async u => { try { const t = await gatherTypes([{urls:[u]}], 5000); return {u, ok:t.has('srflx')}; } catch { return {u, ok:false}; } }));
  // та же проверка, но из основного процесса приложения (Node), в обход WebRTC
  let probe = null;
  if (window.desktop?.probe) {
    const targets = [];
    for (const t of turnTests) {
      const m = /^turns?:([^?:]+|\[[^\]]+\])(?::(\d+))?(?:\?transport=(udp|tcp))?/i.exec(t.url);
      if (m && !/^turns:/i.test(t.url) && !(TPROXY.ports && [TPROXY.ports.udp, TPROXY.ports.tcp].includes(+m[2]))) targets.push({host:m[1], port:+(m[2] || 3478), proto:(m[3] || 'udp').toLowerCase(), url:t.url});
    }
    try { probe = await window.desktop.probe(targets.map(({host, port, proto}) => ({host, port, proto}))); probe.forEach((r, i) => r.url = targets[i]?.url); } catch (e) { probe = null; }
  }
  $('#toast').hidden = true;
  const row = (ok, t) => `<div class="chk"><span>${ok === true ? '✅' : ok === false ? '❌' : '⚠️'}</span><div>${t}</div></div>`;
  const src = hasServerTurn() ? 'TURN вашего сервера' : isTurn(XTURN.servers) ? XTURN.label : '';
  let rtc = null;
  try {
    const dom = S.userId.split(':').slice(1).join(':');
    const r = await fetch(`https://${dom}/.well-known/matrix/client`);
    if (r.ok) { const j = await r.json(); rtc = (j['org.matrix.msc4143.rtc_foci'] || []).map(f => f.livekit_service_url || f.type).filter(Boolean); }
  } catch {}
  const okRelay = types.has('relay') || turnTests.some(t => t.relay);
  const summary = okRelay ? row(true, '<b>Звонки работают</b> — в офисе, через VPN и из любой сети.')
      : types.has('srflx') ? row(null, '<b>Звонки работают в большинстве сетей.</b> Сервер звонков сейчас недоступен — в офисной сети и через VPN соединение может не установиться. Подробности ниже.')
      : row(false, '<b>Звонки сейчас не работают.</b> Проверьте подключение к интернету.');
  const html = summary + '<details class="diag"><summary>Подробности для диагностики</summary>'
    + row(hasServerTurn() ? true : null, hasServerTurn() ? 'Сервер выдаёт ретранслятор TURN' : 'Сервер не выдаёт ретранслятор TURN')
    + turnTests.map(t => row(t.relay, t.relay ? `<code>${esc(t.url)}</code>${TPROXY.ports && new RegExp(':(' + TPROXY.ports.udp + '|' + TPROXY.ports.tcp + ')\\?').test(t.url) ? ' (через приложение → ' + esc(TPROXY.target) + ')' : ''} — работает` : `<code>${esc(t.url)}</code> — ${esc(turnErrText(t.err, t))}${(t.errs || []).length > 1 ? ' <small>(' + esc(t.errs.join('; ')) + ')</small>' : ''}`)).join('')
    + row(stunRes.every(r => r.ok) ? true : stunRes.some(r => r.ok) ? null : false, '<b>STUN без логина (модуль звонков):</b><br>' + stunRes.map(r => `${r.ok ? '✅' : '❌'} <code>${esc(r.u)}</code>`).join('<br>'))
    + (st0 && st1 ? row(st1.udpIn - st0.udpIn > 0 || st1.tcpConn - st0.tcpConn > 0 ? (st1.udpDown - st0.udpDown > 0 || st1.tcpDown - st0.tcpDown > 0 ? true : null) : false,
        `<b>Посредник в приложении:</b> от модуля звонков пришло UDP-пакетов: ${st1.udpIn - st0.udpIn}, отправлено на сервер: ${st1.udpUp - st0.udpUp}, ответов сервера: ${st1.udpDown - st0.udpDown}; TCP-подключений: ${st1.tcpConn - st0.tcpConn}, байт туда/обратно: ${st1.tcpUp - st0.tcpUp}/${st1.tcpDown - st0.tcpDown}${st1.err ? ' · ошибка: ' + esc(st1.err) : ''}${st1.fixed ? ' · исправлено ответов сервера: ' + st1.fixed : ''}${(st1.log || []).length ? '<br><small>Обмен с сервером:<br>' + st1.log.slice(-14).map(esc).join('<br>') + '</small>' : ''}`) : '')
    + (S.iceHosts?.size ? row(null, 'Модуль звонков видит адреса: <code>' + esc([...S.iceHosts].join(', ')) + '</code>') : '')
    + (probe && probe.length ? row(probe.every(r => r.ok) ? true : probe.some(r => r.ok) ? null : false, '<b>Проверка из самого приложения (без WebRTC):</b><br>' + probe.map(r => `${r.ok ? '✅' : '❌'} <code>${esc(r.host)}:${r.port} ${r.proto.toUpperCase()}</code>${r.ok ? ' — отвечает' : ' — ' + esc(r.err || 'нет ответа')}`).join('<br>')
        + (probe.some(r => r.ok) && !turnTests.some(t => t.relay) ? '<br><small>Приложение до сервера достаёт напрямую; звонки идут через посредника в приложении.</small>' : '')) : '')
    + (isMac && (!probe || !probe.some(r => r.ok)) && turnTests.some(t => !t.relay && /\/\/(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(t.url.replace(/^turns?:/, '//')))
      ? row(null, '<b>Mac может не пускать приложение в локальную сеть.</b> Откройте Системные настройки → Конфиденциальность и безопасность → <b>Локальная сеть</b> и включите «Ласточка» (если уже включена — выключите и включите снова: после каждой новой сборки macOS может сбрасывать разрешение). Затем перезапустите Ласточку.') : '')
    + (rtc && rtc.length ? row(null, 'На сервере настроены звонки Element Call (' + esc(rtc.join(', ')) + '). Element звонит через них, а Ласточка — обычными звонками 1:1; для звонка в Element у собеседника должно быть включено «Разрешить резервный сервер для звонков».') : '')
    + (err ? row(false, 'Ошибка проверки: ' + esc(err)) : '') + '</details>';
  const srvT = S.serverTurn()[0];
  const v = await modal({title:'Звонки', html, buttons:[{label:'Проверить снова', value:'again'}, {label:'Закрыть'}]});
  if (v === 'again') callSettings();
  if (v === 'copy') {
    const txt = `URI: ${[].concat(srvT.urls).join(' , ')}\nusername: ${srvT.username}\npassword: ${srvT.credential}`;
    navigator.clipboard?.writeText(txt).then(() => toast('Данные TURN скопированы (действуют ограниченное время)'), () => toast('Не удалось скопировать'));
  }
}
// --- диагностика ICE: какие маршруты нашли мы и собеседник ---
function startIceWatch(call){
  if (CALL.iceT && CALL.diag?.callId === call.callId) return;
  stopIceWatch();
  CALL.diag = {callId:call.callId, local:new Set(), remote:new Set(), pairs:new Set(), ok:false, answered:false, remoteCount:0};
  const poll = async () => {
    const pc = call.peerConn; if (!pc || pc.signalingState === 'closed') return;
    if (pc.remoteDescription) CALL.diag.answered = true;
    try {
      const st = await pc.getStats();
      const d = CALL.diag; let rc = 0;
      st.forEach(r => {
        if (r.type === 'local-candidate' && r.candidateType) d.local.add(r.candidateType);
        if (r.type === 'remote-candidate' && r.candidateType) { d.remote.add(r.candidateType); rc++; }
        if (r.type === 'candidate-pair' && r.state) { d.pairs.add(r.state); if (r.state === 'succeeded' && r.nominated) d.ok = true; }
      });
      d.remoteCount = Math.max(d.remoteCount, rc);
    } catch {}
  };
  poll(); CALL.iceT = setInterval(poll, 1500);
}
function stopIceWatch(){ clearInterval(CALL.iceT); CALL.iceT = null; }
const ROUTE = {host:'локальная сеть', srflx:'внешний адрес (STUN)', prflx:'внешний адрес', relay:'ретранслятор (TURN)'};
const routes = set => [...set].map(t => ROUTE[t] || t).join(', ') || 'нет';
function offerFallback(d){
  d = d || {local:new Set(), remote:new Set(), remoteCount:0};
  let why;
  if (!d.remoteCount) why = '<b>От собеседника не пришло ни одного маршрута.</b> Его приложение не отправило данные для соединения — попросите собеседника обновить приложение и перезапустить его.';
  else if (!d.remote.has('srflx') && !d.remote.has('prflx') && !d.remote.has('relay')) why = '<b>Собеседник знает только свой адрес в локальной сети.</b> Если он в Element — нужно включить «Разрешить резервный сервер для звонков» (Настройки → Голос и видео) и перезапустить Element. Если в Ласточке — обновить её до последней версии.';
  else if (!d.local.has('srflx') && !d.local.has('relay')) why = '<b>У вас не нашёлся внешний адрес.</b> Вероятно, исходящий UDP закрыт сетью или VPN. Попробуйте другую сеть или отключите VPN.';
  else if (!d.local.has('relay') && !d.remote.has('relay')) why = '<b>Маршруты с обеих сторон есть, но NAT не пропустил прямое соединение</b> (строгий NAT — офисный шлюз или мобильный оператор). Такой звонок проходит только через ретранслятор TURN.';
  else why = '<b>Не удалось соединиться даже через ретранслятор.</b> Проверьте подключение к интернету у обоих.';
  const row = (k, v) => `<div class="info-row"><small>${k}</small>${esc(v)}</div>`;
  modal({title:'Не удалось соединиться', html:`<p>${why}</p>` + row('Ваши маршруты', routes(d.local)) + row('Маршруты собеседника', d.remoteCount ? routes(d.remote) : 'не получены'),
    buttons:[{label:'Проверка звонков', value:'d'}, {label:'Закрыть', value:true}]}).then(v => { if (v === 'd') callSettings(); });
}

/* ---------- звонки 1:1 (голос и видео), совместимые с Element Classic ---------- */
// Сигнализация — события m.call.* в чате (в зашифрованных чатах они шифруются),
// звук и видео идут напрямую между устройствами по WebRTC (DTLS-SRTP),
// при сложной сети — через TURN-сервер, который выдаёт ваш Synapse.
const CALL = {call:null, timer:null, started:0, ring:null};
const callAllowed = room => !!room && canSend(room) && isDM(room) && !!S.client?.supportsVoip?.();
function ringtone(kind){
  stopRing();
  try {
    const ctx = new AudioContext(), g = ctx.createGain(); g.gain.value = 0; g.connect(ctx.destination);
    const o1 = ctx.createOscillator(), o2 = ctx.createOscillator();
    o1.frequency.value = kind === 'in' ? 660 : 425; o2.frequency.value = kind === 'in' ? 880 : 425;
    o1.connect(g); o2.connect(g); o1.start(); o2.start();
    const beat = () => {
      const t = ctx.currentTime;
      g.gain.cancelScheduledValues(t); g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(kind === 'in' ? 0.18 : 0.08, t + 0.05);
      g.gain.setValueAtTime(kind === 'in' ? 0.18 : 0.08, t + (kind === 'in' ? 0.9 : 1.0));
      g.gain.exponentialRampToValueAtTime(0.0001, t + (kind === 'in' ? 1.0 : 1.1));
    };
    beat();
    CALL.ring = {ctx, iv:setInterval(beat, kind === 'in' ? 2000 : 4000)};
  } catch {}
}
// короткий сигнал завершения звонка: два мягких тона вниз (как в мессенджерах)
function hangupSound(){
  try {
    const ctx = new AudioContext(), t0 = ctx.currentTime + 0.02;
    [[660, 0], [440, 0.22]].forEach(([f, dt]) => {
      const o = ctx.createOscillator(), g = ctx.createGain();
      o.type = 'sine'; o.frequency.value = f; o.connect(g); g.connect(ctx.destination);
      g.gain.setValueAtTime(0, t0 + dt); g.gain.linearRampToValueAtTime(0.18, t0 + dt + 0.02);
      g.gain.setValueAtTime(0.18, t0 + dt + 0.16); g.gain.linearRampToValueAtTime(0, t0 + dt + 0.2);
      o.start(t0 + dt); o.stop(t0 + dt + 0.22);
    });
    setTimeout(() => ctx.close().catch(() => {}), 800);
  } catch {}
}
function stopRing(){ if (CALL.ring) { clearInterval(CALL.ring.iv); CALL.ring.ctx.close().catch(() => {}); CALL.ring = null; } }
function callPeer(call){
  const room = S.client.getRoom(call.roomId);
  const uid = call.getOpponentMember?.()?.userId || (room && dmPartnerOf(room)) || '';
  return {room, uid, name:room ? roomName(room) : localpart(uid), avatar:room?.getMember(uid)?.getMxcAvatarUrl() || ''};
}
const CALL_STATE_TEXT = {fledgling:'Подготовка…', wait_local_media:'Доступ к микрофону…', create_offer:'Вызов…', invite_sent:'Вызов…', create_answer:'Соединение…', connecting:'Соединение…', ringing:'Входящий звонок', ended:'Звонок завершён'};
function fmtCall(sec){ const m = Math.floor(sec / 60), s = sec % 60; return (m >= 60 ? Math.floor(m / 60) + ':' + String(m % 60).padStart(2, '0') : m) + ':' + String(s).padStart(2, '0'); }
function cbtn(act, icon, label, cls = ''){ return `<button class="cb ${cls}" data-call="${act}" title="${esc(label)}"><span class="cb-i">${icon}</span><span class="cb-l">${esc(label)}</span></button>`; }
function renderCall(){
  const el = $('#call'), call = CALL.call;
  if (!call) { el.hidden = true; el.innerHTML = ''; el.className = 'call'; document.body.classList.remove('call-mini'); return; }
  const {uid, name, avatar} = callPeer(call);
  const st = call.state, incoming = call.direction === 'inbound' && st === 'ringing';
  const video = call.type === 'video';
  const status = st === 'connected' ? fmtCall(Math.round((Date.now() - CALL.started) / 1000)) : (CALL_STATE_TEXT[st] || '…');
  if (S.locked && incoming) { el.hidden = true; return; }
  const mini = !!CALL.mini && !incoming;
  el.className = 'call' + (mini ? ' mini' : '');
  document.body.classList.toggle('call-mini', mini);
  const camOff = call.isLocalVideoMuted();
  const statusText = incoming ? (video ? '📹 Входящий видеозвонок' : '📞 Входящий звонок') : status;
  if (mini) {
    el.innerHTML = `<video id="call-remote" class="call-remote" autoplay playsinline></video>
      <button class="cm-body" data-call="expand" title="Вернуться к звонку">${avatarHTML(avatar, uid, name, 40)}<span class="cm-t"><b>${esc(name)}</b><span id="call-status">${esc(statusText)}</span></span></button>
      <div class="cm-btns"><button class="cmb ${CALL.muted ? 'on' : ''}" data-call="mic" title="${CALL.muted ? 'Включить микрофон' : 'Выключить микрофон'}">${CALL.muted ? I.micOff : I.mic}</button>
      <button class="cmb" data-call="expand" title="Развернуть">${I.expand}</button>
      <button class="cmb red" data-call="hangup" title="Завершить">${I.hang}</button></div>`;
  } else {
    el.innerHTML = `<video id="call-remote" class="call-remote" autoplay playsinline></video>
      <video id="call-local" class="call-local" autoplay playsinline muted></video>
      ${incoming ? '' : `<button class="call-min" data-call="minimize" title="Свернуть — можно переписываться во время звонка">${I.chevDown}<span>Свернуть</span></button>`}
      <div class="call-info">${avatarHTML(avatar, uid, name, 120)}<div class="call-name">${esc(name)}</div>
        <div class="call-status" id="call-status">${esc(statusText)}</div>
        <div class="call-e2e">${I.lock} Защищено сквозным шифрованием</div></div>
      <div class="call-bar">${incoming
        ? cbtn('reject', I.hang, 'Отклонить', 'red') + cbtn('answer', I.phone, 'Ответить', 'green') + (video ? cbtn('answer-video', I.cam, 'С видео', 'green') : '')
        : cbtn('mic', CALL.muted ? I.micOff : I.mic, CALL.muted ? 'Микрофон выкл.' : 'Микрофон', CALL.muted ? 'on' : '')
          + cbtn('cam', camOff ? I.camOff : I.cam, camOff ? 'Камера выкл.' : 'Камера', camOff ? 'on' : '')
          + (!camOff ? cbtn('self', CALL.hideSelf ? I.eyeOff : I.eye, CALL.hideSelf ? 'Показать себя' : 'Скрыть себя', CALL.hideSelf ? 'on' : '') : '')
          + cbtn('minimize', I.chat, 'К чатам')
          + cbtn('hangup', I.hang, 'Завершить', 'red')}</div>`;
  }
  el.hidden = false;
  hydrate(el);
  attachFeeds();
}
function attachFeeds(){
  const call = CALL.call; if (!call) return;
  const rv = $('#call-remote'), lv = $('#call-local');
  const remote = call.getRemoteFeeds().find(f => f.purpose !== 'm.screenshare') || call.getRemoteFeeds()[0];
  const local = call.getLocalFeeds()[0];
  if (rv && remote?.stream && rv.srcObject !== remote.stream) rv.srcObject = remote.stream;
  if (lv && local?.stream && lv.srcObject !== local.stream) lv.srcObject = local.stream;
  const remoteVid = !!remote?.stream?.getVideoTracks().length && !remote.isVideoMuted();
  const localVid = !!local?.stream?.getVideoTracks().length && !call.isLocalVideoMuted();
  $('#call').classList.toggle('has-video', remoteVid);
  if (lv) lv.hidden = !localVid || !!CALL.hideSelf;
  if (rv) rv.hidden = !remote?.stream;
}
// Выключение микрофона: и через библиотеку (собеседник видит значок), и напрямую на всех
// исходящих аудиодорожках соединения — так звук гарантированно не уходит.
function applyMute(call){
  const m = !!CALL.muted;
  try { call.setMicrophoneMuted(m).catch(() => {}); } catch {}
  try { call.localUsermediaStream?.getAudioTracks().forEach(t => { t.enabled = !m; }); } catch {}
  try { call.peerConn?.getSenders().forEach(snd => { if (snd.track?.kind === 'audio') snd.track.enabled = !m; }); } catch {}
}
function bindCall(call){
  if (CALL.call !== call) { CALL.muted = false; CALL.mini = false; CALL.hideSelf = false; }
  CALL.call = call;
  call.on('state', st => {
    if (st === 'connected') { stopRing(); CALL.started = Date.now(); clearInterval(CALL.timer); CALL.timer = setInterval(() => { const s = $('#call-status'); if (s && CALL.call?.state === 'connected') s.textContent = fmtCall(Math.round((Date.now() - CALL.started) / 1000)); }, 1000); }
    if (st === 'ended') { endCall(call); return; }
    if (st === 'invite_sent') ringtone('out');
    if (st === 'connecting' || st === 'create_answer' || st === 'invite_sent') startIceWatch(call);
    if (st === 'connected') { stopIceWatch(); if (CALL.diag) CALL.diag.ok = true; if (CALL.muted) applyMute(call); }
    if (st === 'connecting') {
      clearTimeout(CALL.slow);
      CALL.slow = setTimeout(() => { if (CALL.call === call && call.state === 'connecting') { const s = $('#call-status'); if (s) s.textContent = 'Ищем маршрут до собеседника…'; } }, 12000);
    }
    renderCall();
  });
  call.on('feeds_changed', () => { attachFeeds(); if (CALL.muted) applyMute(call); });
  // При «встречном» звонке библиотека заменяет звонок новым — переключаемся на него,
  // иначе кнопки управляли бы старым звонком, а звук шёл бы по новому.
  call.on('replaced', newCall => { if (CALL.call === call) { bindCall(newCall); if (CALL.muted) applyMute(newCall); } });
  call.on('local_hold_unhold', renderCall);
  call.on('remote_hold_unhold', renderCall);
  call.on('hangup', () => endCall(call));
  call.on('error', err => {
    const code = err?.code || '';
    if (code === 'ice_failed' || code === 'ice_timeout') return;
    toast(code === 'no_user_media' ? 'Нет доступа к микрофону или камере. Разрешите их в Системных настройках → Конфиденциальность'
      : 'Ошибка звонка: ' + (err?.message || code));
  });
  renderCall();
}
function endCall(call){
  if (CALL.call !== call || call.__lastochkaEnded) return;
  call.__lastochkaEnded = true;
  hangupSound();
  window.desktop?.clearNotify?.('call');
  stopRing(); clearInterval(CALL.timer);
  const reason = call.hangupReason;
  clearTimeout(CALL.slow);
  const diag = CALL.diag; stopIceWatch();
  if (reason === 'ice_failed' || reason === 'ice_timeout' || (diag && !diag.ok && call.state !== 'connected' && diag.answered)) setTimeout(() => offerFallback(diag), 1300);
  const REASONS = {invite_timeout:'Нет ответа', user_busy:'Абонент занят', ice_failed:'Не удалось соединиться', ice_timeout:'Не удалось соединиться', user_media_failed:'Нет доступа к микрофону', no_user_media:'Не найден микрофон', unknown_devices:'Есть неподтверждённые устройства', answered_elsewhere:'Отвечено на другом устройстве', user_hangup:'Звонок завершён', remote_hangup:'Собеседник завершил звонок'};
  const st = $('#call-status'); if (st) st.textContent = REASONS[reason] || (reason ? 'Звонок завершён (' + reason + ')' : 'Звонок завершён');
  $('#call')?.querySelectorAll('video').forEach(v => { v.srcObject = null; });
  setTimeout(() => { if (CALL.call === call) { CALL.call = null; renderCall(); } }, 1200);
}
async function startCall(video){
  const room = cur();
  if (!callAllowed(room)) { toast('Звонить можно только в личном чате'); return; }
  if (CALL.call) { toast('Сначала завершите текущий звонок'); return; }
  const call = sdk.createNewMatrixCall(S.client, room.roomId);
  if (!call) { toast('Звонки не поддерживаются на этом устройстве'); return; }
  bindCall(call);
  try { await (video ? call.placeVideoCall() : call.placeVoiceCall()); }
  catch (e) { toast('Не удалось позвонить: ' + e.message); endCall(call); }
}
function onIncomingCall(call){
  if (CALL.call && CALL.call !== call) { call.hangup('user_busy', false); return; }
  bindCall(call);
  window.desktop?.show?.();
  ringtone('in');
  if (notifCfg().on && (document.hidden || !document.hasFocus() || S.locked)) {
    const {name} = callPeer(call);
    sysNotify({title:S.locked ? 'Ласточка' : name, body:S.locked ? 'Входящий звонок — разблокируйте приложение' : (call.type === 'video' ? 'Входящий видеозвонок' : 'Входящий звонок'), tag:'call', urgent:true});
  }

}
$('#call').addEventListener('click', e => {
  const b = e.target.closest('[data-call]'), call = CALL.call; if (!b) return;
  if (!call) { renderCall(); return; }
  const a = b.dataset.call;
  if (a === 'answer' || a === 'answer-video') { stopRing(); CALL.mini = false; call.answer(true, a === 'answer-video'); }
  else if (a === 'reject') { stopRing(); try { call.reject(); } catch {} setTimeout(() => { if (CALL.call === call) { endCall(call); CALL.call = null; renderCall(); } }, 400); }
  else if (a === 'hangup') {
    // кнопка всегда закрывает экран звонка, даже если звонок уже «завис» в завершённом состоянии
    try { if (call.state !== 'ended') call.hangup('user_hangup', false); } catch {}
    setTimeout(() => { if (CALL.call === call) { endCall(call); CALL.call = null; renderCall(); } }, 400);
  }
  else if (a === 'mic') { CALL.muted = !CALL.muted; applyMute(call); renderCall(); }
  else if (a === 'minimize') { CALL.mini = true; renderCall(); }
  else if (a === 'expand') { CALL.mini = false; renderCall(); }
  else if (a === 'self') { CALL.hideSelf = !CALL.hideSelf; renderCall(); }
  else if (a === 'cam') { Promise.resolve(call.setLocalVideoMuted(!call.isLocalVideoMuted())).then(renderCall).catch(err => toast('Камера: ' + err.message)); }
});
$('#call-voice').onclick = () => startCall(false);
$('#call-video').onclick = () => startCall(true);
function updateCallBtns(){
  const ok = callAllowed(cur());
  $('#call-voice').hidden = !ok; $('#call-video').hidden = !ok;
}
window.addEventListener('beforeunload', () => { try { CALL.call?.hangup('user_hangup', false); } catch {} });
function callText(room, ev){
  const t = ev.getType(), c = ev.getContent() || {};
  if (t !== 'm.call.invite' && t !== 'm.call.hangup' && t !== 'm.call.reject') return null;
  const mine = ev.getSender() === S.userId;
  const evs = liveEvents(room), same = x => (x.getContent() || {}).call_id === c.call_id;
  if (t === 'm.call.invite') {
    const video = String(c.offer?.sdp || '').includes('m=video');
    const ans = evs.find(x => x.getType() === 'm.call.answer' && same(x));
    const end = evs.find(x => (x.getType() === 'm.call.hangup' || x.getType() === 'm.call.reject') && same(x));
    const kind = video ? 'видеозвонок' : 'звонок';
    if (!ans && end) return mine ? `📞 Отменённый ${kind}` : `📞 Пропущенный ${kind}`;
    const dur = ans && end ? ' · ' + fmtCall(Math.max(0, Math.round((end.getTs() - ans.getTs()) / 1000))) : '';
    return `📞 ${mine ? 'Исходящий' : 'Входящий'} ${kind}${dur}`;
  }
  return null;
}

/* ---------- theme ---------- */
// ---------- защита от снимков экрана ----------
const LS_PROTECT = 'lastochka.protect';
function protectOn(){ try { return localStorage.getItem(LS_PROTECT) === '1'; } catch { return false; } }
function setProtect(on){ try { localStorage.setItem(LS_PROTECT, on ? '1' : '0'); } catch {} window.desktop?.protect?.(on); toast(on ? 'Окно скрыто от скриншотов и записи экрана' : 'Защита от скриншотов выключена'); }
if (protectOn()) window.desktop?.protect?.(true);
// ---------- обновления (GitHub Releases, проверка подписи — в основном процессе) ----------
const UPD = {info:null, busy:false, pct:0};
function renderUpd(){
  const b = $('#updbar'); if (!b) return;
  const i = UPD.info;
  if (!i) { b.hidden = true; return; }
  b.innerHTML = UPD.busy
    ? `<div class="ub-t"><b>Скачиваем Ласточку ${esc(i.version)}…</b><span>${UPD.pct}%</span></div><div class="ub-bar"><i style="width:${UPD.pct}%"></i></div>`
    : `<div class="ub-t"><b>Доступна Ласточка ${esc(i.version)}</b><span>${i.platform === 'darwin' ? 'Скачаем и откроем установщик' : i.portable ? 'Скачаем новую версию рядом с текущей' : 'Обновится и перезапустится'}</span></div><button class="ub-go" data-upd="go">Обновить</button><button class="ub-x" data-upd="later" title="Позже">✕</button>`;
  b.hidden = false;
}
async function checkUpdate(manual){
  const U = window.desktop?.update; if (!U) { if (manual) toast('Обновления работают только в приложении'); return; }
  try {
    if (manual) toast('Проверяем обновления…', true);
    const r = await U.check();
    if (r.upToDate) { UPD.info = null; if (manual) toast(`У вас последняя версия (${r.current})`); }
    else { UPD.info = r; if (manual) $('#toast').hidden = true; }
    renderUpd();
  } catch (e) { if (manual) toast('Не удалось проверить обновления: ' + (e.message || e)); }
}
window.desktop?.update?.onProgress(p => { UPD.pct = p; renderUpd(); });
$('#updbar').addEventListener('click', async e => {
  const b = e.target.closest('[data-upd]'); if (!b) return;
  if (b.dataset.upd === 'later') { UPD.info = null; renderUpd(); return; }
  if (UPD.busy) return;
  UPD.busy = true; UPD.pct = 0; renderUpd();
  try {
    const r = await window.desktop.update.install();
    if (r.mode === 'dmg') toast('Установщик открыт: перетащите «Ласточку» в «Программы» и запустите заново', true);
    else if (r.mode === 'portable') toast('Новая версия сохранена рядом с текущей — запустите её', true);
    else toast('Устанавливаем обновление… Ласточка перезапустится', true);
  } catch (err) { toast(err.message || String(err)); }
  UPD.busy = false; UPD.info = null; renderUpd();
});
setTimeout(() => checkUpdate(false), 15e3);
setInterval(() => checkUpdate(false), 6 * 3600e3);
// ---------- заставка при запуске ----------
function splashText(t){ const e = $('#sp-text'); if (e && !$('#splash')?.hidden) e.textContent = t; }
function hideSplash(){
  const sp = $('#splash'); if (!sp || sp.hidden || sp.classList.contains('out')) return;
  sp.classList.add('out'); setTimeout(() => { sp.hidden = true; }, 450);
}
setTimeout(hideSplash, 20e3); // на всякий случай: не держим заставку дольше 20 с
// ---------- кнопка «Новый чат» в списке чатов ----------
document.querySelectorAll('[data-ico]').forEach(e => { e.innerHTML = I_(e.dataset.ico); });
$('#fab').onclick = e => { e.stopPropagation(); const m = $('#fab-menu'); m.hidden = !m.hidden; $('#menu').hidden = true; };
$('#fab-menu').addEventListener('click', e => {
  const b = e.target.closest('[data-f]'); if (!b) return;
  $('#fab-menu').hidden = true; S.settingsNav = false;
  ({dm:newDM, group:newGroup, join:joinRoom})[b.dataset.f]?.();
});
document.addEventListener('mousedown', e => { if (!$('#fab-menu').hidden && !e.target.closest('#fab-menu, #fab')) $('#fab-menu').hidden = true; });
// ---------- Windows: свой заголовок окна, шрифт Inter и цветные эмодзи Noto ----------
const IS_WIN = /Win/i.test(navigator.userAgentData?.platform || navigator.platform || '');
// macOS: свой заголовок со значком, «светофор» системы — слева поверх него
if (window.desktop && isMac) { document.body.classList.add('mac'); $('#titlebar').hidden = false; }
if (IS_WIN) {
  document.body.classList.add('win');
  $('#titlebar').hidden = false;
  try {
    for (const [w, f] of [[400, 'Regular'], [500, 'Medium'], [600, 'SemiBold'], [700, 'Bold']]) {
      const ff = new FontFace('Inter', `url(./fonts/Inter-${f}.woff)`, {weight:String(w), display:'swap'});
      document.fonts.add(ff); ff.load().catch(() => {});
    }
    // Цветные эмодзи вместо плоских Segoe UI Emoji (только для символов-эмодзи)
    const em = new FontFace('Lastochka Emoji', 'url(./fonts/NotoColorEmoji.ttf)', {display:'swap',
      unicodeRange:'U+200D,U+203C,U+2049,U+2139,U+2194-2199,U+21A9-21AA,U+231A-231B,U+2328,U+23CF,U+23E9-23F3,U+23F8-23FA,U+24C2,U+25AA-25AB,U+25B6,U+25C0,U+25FB-25FE,U+2600-27BF,U+2934-2935,U+2B05-2B07,U+2B1B-2B1C,U+2B50,U+2B55,U+3030,U+303D,U+3297,U+3299,U+FE0F,U+1F000-1FAFF,U+E0020-E007F'});
    document.fonts.add(em); em.load().catch(() => {});
  } catch {}
}
// ---------- оформление: акцент, фон, компактный список, размер текста ----------
const LS_LOOK = 'lastochka.look';
const ACCENTS = [['', 'Как в теме'], ['#3390ec', 'Синий'], ['#8774e1', 'Фиолетовый'], ['#22a06b', 'Зелёный'], ['#14b8a6', 'Бирюзовый'], ['#f59e0b', 'Оранжевый'], ['#e53935', 'Красный'], ['#ec4899', 'Розовый'], ['#64748b', 'Графит']];
const WALLS = [['', 'Узор'], ['plain', 'Однотонный'], ['ocean', 'Океан'], ['sunset', 'Закат'], ['mint', 'Мята'], ['night', 'Ночь']];
const ZOOMS = [[0.9, 'Мелкий'], [1, 'Обычный'], [1.12, 'Крупный'], [1.25, 'Очень крупный']];
function lookCfg(){ try { return {accent:'', wall:'', compact:false, zoom:1, ...JSON.parse(localStorage.getItem(LS_LOOK) || '{}')}; } catch { return {accent:'', wall:'', compact:false, zoom:1}; } }
function applyLook(){
  const L = lookCfg(), r = document.documentElement.style;
  for (const k of ['--accent', '--row-active', '--badge', '--out']) r.removeProperty(k);
  if (L.accent) {
    r.setProperty('--accent', L.accent); r.setProperty('--row-active', L.accent);
    if (document.documentElement.dataset.theme === 'dark') { r.setProperty('--badge', L.accent); r.setProperty('--out', `color-mix(in srgb, ${L.accent} 78%, #1b1b1b)`); }
  }
  document.documentElement.dataset.wall = L.wall || '';
  document.body.classList.toggle('compact', !!L.compact);
  r.setProperty('--mz', String(L.zoom || 1));
}
function setLook(patch){ try { localStorage.setItem(LS_LOOK, JSON.stringify({...lookCfg(), ...patch})); } catch {} applyLook(); }
async function lookDialog(kind){
  const L = lookCfg();
  const list = kind === 'accent' ? ACCENTS : kind === 'wall' ? WALLS : ZOOMS;
  const curV = kind === 'accent' ? L.accent : kind === 'wall' ? L.wall : L.zoom;
  const html = `<div class="look-grid ${kind}">${list.map(([v, t]) => `<button class="look-i${String(v) === String(curV) ? ' on' : ''}" data-v="${v}">${kind === 'accent' ? `<span class="sw-c" style="background:${v || 'var(--accent)'}"></span>` : kind === 'wall' ? `<span class="sw-w" style="background:${({'':'var(--wall-base) var(--wall)', plain:'#cfd6de', ocean:'linear-gradient(160deg,#a8d8ff,#4c7fd1)', sunset:'linear-gradient(160deg,#ffd29d,#c98bd6)', mint:'linear-gradient(160deg,#d9f7e8,#88d1b9)', night:'linear-gradient(160deg,#5b5f99,#2d3158)'})[v]}"></span>` : `<span class="sw-z" style="font-size:${Math.round(15 * v)}px">Аа</span>`}<small>${esc(t)}</small></button>`).join('')}</div>`;
  panel(`<h3>${kind === 'accent' ? 'Цвет акцента' : kind === 'wall' ? 'Фон чатов' : 'Размер текста в чатах'}</h3>${html}`, v => {
    setLook(kind === 'accent' ? {accent:v} : kind === 'wall' ? {wall:v} : {zoom:+v});
    lookDialog(kind);
  }, {back:true, cls:'st-dlg'});
}
function setTheme(t, save){
  document.documentElement.dataset.theme = t;
  applyLook();
  if (IS_WIN) requestAnimationFrame(() => { const cs = getComputedStyle(document.body); window.desktop?.titleBar?.(cs.getPropertyValue('--side-bg').trim() || (t === 'dark' ? '#212121' : '#ffffff'), t === 'dark' ? '#ffffff' : '#000000'); });
  document.querySelector('meta[name="theme-color"]').content = t === 'dark' ? '#212121' : '#ffffff';
  if (save) try { localStorage.setItem(LS_THEME, t); } catch {}
}
{
  let t = null; try { t = localStorage.getItem(LS_THEME); } catch {}
  setTheme(t || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'));
}

/* ---------- DOM events ---------- */
$('#list').addEventListener('click', e => {
  const r = e.target.closest('[data-room]'); if (!r) return;
  openRoom(r.dataset.room);
  if (r.dataset.ev) { const id = r.dataset.ev; requestAnimationFrame(() => jumpTo(id)); }
});
$('#list').addEventListener('keydown', e => { if (e.key === 'Enter') { const r = e.target.closest('[data-room]'); if (r) openRoom(r.dataset.room); } });
$('#search').addEventListener('input', e => { S.search = e.target.value; renderList(); });
$('#back').onclick = closeChat;
$('#head-click').onclick = showInfo;
$('#info-btn').onclick = showInfo;
$('#down').onclick = () => { const b = $('#messages'); b.scrollTo({top:b.scrollHeight, behavior:'smooth'}); };
$('#send').onclick = () => {
  if (S.recording) return finishRecording();
  if ($('#send').dataset.mode === 'mic') return startRecording();
  sendText(); $('#input').focus();
};
$('#rec-cancel').onclick = cancelRecording;
$('#attach').onclick = () => $('#file').click();
$('#file').onchange = e => { [...e.target.files].forEach(sendFile); e.target.value = ''; };
$('#input').addEventListener('input', () => { autosize(); updateSendBtn(); sendTyping(!!$('#input').value.trim()); });
$('#input').addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); sendText(); }
  else if (e.key === 'Escape' && (S.reply || S.editing)) { e.preventDefault(); cancelBar(); }
  else if (e.key === 'ArrowUp' && !$('#input').value) {
    const room = cur(); if (!room) return;
    const ev = [...liveEvents(room)].reverse().find(x => x.getSender() === S.userId && isMsg(x) && x.getType() === 'm.room.message' && !x.isRedacted() && !x.status && ['m.text', 'm.emote'].includes(x.getContent()?.msgtype));
    if (ev) { e.preventDefault(); startEdit(ev.getId()); }
  }
});
$('#input').addEventListener('paste', e => {
  const files = [...(e.clipboardData?.files || [])];
  if (files.length) { e.preventDefault(); files.forEach(sendFile); }
});
$('#bar').addEventListener('click', e => { if (e.target.closest('[data-act="cancel-bar"]')) cancelBar(); });
$('#lockbar').addEventListener('click', e => {
  const b = e.target.closest('[data-act]'); const room = cur(); if (!b || !room) return;
  if (b.dataset.act === 'accept') acceptInvite(room); else if (b.dataset.act === 'decline') leaveRoom(room);
});
const box = $('#messages');
box.addEventListener('scroll', () => {
  const room = cur();
  if (room && box.scrollTop < 400) older(room);
  updateDown(); markRead(); updateFloatDate();
}, {passive:true});
box.addEventListener('click', e => {
  if (linkHeld && e.target.closest('a')) { e.preventDefault(); linkHeld = false; return; }
  const room = cur(); if (!room) return;
  const mb = e.target.closest('[data-more]');
  if (mb) { e.stopPropagation(); const r = mb.getBoundingClientRect(); openCtx(r.left, r.bottom + 4, mb.closest('[data-id]').dataset.id); return; }
  const j = e.target.closest('[data-jump]'); if (j) return jumpTo(j.dataset.jump);
  const rc = e.target.closest('[data-react]');
  if (rc) { const row = rc.closest('[data-id]'); if (row && canSend(room)) toggleReaction(room, row.dataset.id, rc.dataset.react); return; }
  const fail = e.target.closest('.fail');
  if (fail) { const ev = room.findEventById(fail.closest('[data-id]')?.dataset.id); if (ev) S.client.resendEvent(ev, room).catch(() => {}); return; }
  if (e.target.closest('[data-vspeed]')) {
    P.rate = P.rate === 1 ? 1.5 : P.rate === 1.5 ? 2 : 1; P.audio.playbackRate = P.rate;
    try { localStorage.setItem('lastochka.vrate', String(P.rate)); } catch {}
    document.querySelectorAll('[data-vspeed]').forEach(b => b.textContent = P.rate + '×');
    return;
  }
  const vp = e.target.closest('.vplay');
  if (vp) { const ev = room.findEventById(vp.closest('.voice').dataset.voice); if (ev) togglePlay(room, ev); return; }
  const vw = e.target.closest('.vwave');
  if (vw) { seekVoice(vw.closest('.voice'), e.clientX); return; }
  const vid = e.target.closest('[data-video-ev]');
  if (vid) { const ev = room.findEventById(vid.dataset.videoEv); if (ev) openVideo(ev); return; }
  const ph = e.target.closest('[data-full],[data-full-ev]');
  if (ph) { const ev = room.findEventById(ph.closest('[data-id]')?.dataset.id); if (ev && viewable(ev)) openViewer(room, ev); return; }
  const f = e.target.closest('[data-dl-ev]');
  if (f) { const ev = room.findEventById(f.dataset.dlEv); if (ev) downloadEvent(ev); }
});
box.addEventListener('contextmenu', e => {
  const a = e.target.closest('a[href]');
  if (a) { e.preventDefault(); linkCancel(); openLinkCtx(e.clientX, e.clientY, a.href); return; }
  const row = e.target.closest('.bubble')?.closest('[data-id]');
  if (!row) return;
  e.preventDefault(); openCtx(e.clientX, e.clientY, row.dataset.id);
});
box.addEventListener('mousedown', e => { if (e.button === 0) linkHold(e, e.clientX, e.clientY); });
['mouseup', 'mouseleave', 'dragstart'].forEach(n => box.addEventListener(n, linkCancel));
let lpT;
box.addEventListener('touchstart', e => {
  const t = e.touches[0];
  if (e.target.closest('a[href]')) { linkHold(e, t.clientX, t.clientY); return; }
  const row = e.target.closest('.bubble')?.closest('[data-id]'); if (!row) return;
  lpT = setTimeout(() => { navigator.vibrate?.(10); openCtx(t.clientX, t.clientY, row.dataset.id); }, 450);
}, {passive:true});
['touchend', 'touchmove', 'touchcancel'].forEach(n => box.addEventListener(n, () => { clearTimeout(lpT); linkCancel(); }, {passive:true}));
document.addEventListener('click', e => {
  if (!e.target.closest('#ctx')) closeCtx();
  if (e.target.isConnected && !e.target.closest('#picker, #emoji-btn, #sticker-btn, #ctx, #modal')) closePicker();
  if (!e.target.closest('#menu') && !e.target.closest('#menu-btn')) $('#menu').hidden = true;
});
document.addEventListener('keydown', e => {
  if (S.locked) return;
  const mod = e.metaKey || e.ctrlKey;
  if (mod && (e.key === 'l' || e.key === 'д') && lockCfg()) { e.preventDefault(); return lockApp(); }
  if (mod && (e.key === 'f' || e.key === 'а') && S.current && $('#modal').hidden) { e.preventDefault(); return openFind(); }
  if (!$('#lightbox').hidden && $('#modal').hidden && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) { e.preventDefault(); return viewerStep(e.key === 'ArrowLeft' ? -1 : 1); }
  if (e.key !== 'Escape' || !$('#modal').hidden) return;
  if (!$('#sres').hidden) { $('#sres').hidden = true; return; }
  if (S.find) return closeFind();
  if (!$('#ctx').hidden) return closeCtx();
  if (!$('#lightbox').hidden) return closeViewer();
  if (!$('#ctx').hidden) return closeCtx();
  if (!$('#picker').hidden) return closePicker();
  if (S.recording) return cancelRecording();
  if (!$('#menu').hidden) { $('#menu').hidden = true; return; }
  if (S.current && !S.reply && !S.editing) closeChat();
});
document.addEventListener('visibilitychange', () => { if (!document.hidden) { markRead(); schedule(true, false); } });
window.addEventListener('focus', markRead);
const chatEl = $('#chat'); let dragDepth = 0;
chatEl.addEventListener('dragenter', e => { if (canSend(cur()) && e.dataTransfer?.types?.includes('Files')) { dragDepth++; document.body.classList.add('drop'); } });
chatEl.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; document.body.classList.remove('drop'); } });
chatEl.addEventListener('dragover', e => { if (canSend(cur())) e.preventDefault(); });
chatEl.addEventListener('drop', e => { e.preventDefault(); dragDepth = 0; document.body.classList.remove('drop'); [...(e.dataTransfer?.files || [])].forEach(sendFile); });

/* ---------- notifications ---------- */
// Системные уведомления: в приложении — через Центр уведомлений macOS / Windows (main-процесс),
// в браузере — через Web Notifications. Настройки — «Настройки → Уведомления».
const LS_NOTIF = 'lastochka.notif';
const notifCfg = () => { try { return {on:true, preview:true, sound:true, ...JSON.parse(localStorage.getItem(LS_NOTIF) || '{}')}; } catch { return {on:true, preview:true, sound:true}; } };
function sysNotify({title, body, tag, urgent}){
  const c = notifCfg();
  if (window.desktop?.notify) { window.desktop.notify({title, body, tag, urgent, silent:!c.sound}); return; }
  if (!('Notification' in window) || Notification.permission !== 'granted') return;
  try {
    const n = new Notification(title, {body, tag, silent:!c.sound, requireInteraction:!!urgent});
    n.onclick = () => { window.focus(); onNotifyClick(tag); n.close(); };
  } catch {}
}
function onNotifyClick(tag){
  if (S.locked || !tag || tag === 'locked') return;
  if (tag === 'call') return;
  if (S.client?.getRoom(tag)) openRoom(tag);
}
window.desktop?.onNotifyClick?.(onNotifyClick);
function maybeNotify(ev, room){
  if (ev.getSender() === S.userId || !notifCfg().on) return;
  const go = () => {
    if (!isMsg(ev) || ev.isRedacted()) return;
    const visible = !document.hidden && document.hasFocus();
    if (visible && S.current === room.roomId && !S.locked) return;
    const act = S.client.getPushActionsForEvent(ev, true);
    if (!act?.notify) return;
    const c = notifCfg();
    if (S.locked) return sysNotify({title:'Ласточка', body:'Новое сообщение', tag:'locked'});
    const who = isDM(room) ? '' : memberName(room, ev.getSender()) + ': ';
    sysNotify({title:roomName(room), body:c.preview ? who + snippet(room, ev) : (isDM(room) ? 'Новое сообщение' : who + 'новое сообщение'), tag:room.roomId});
  };
  if (ev.getType() === 'm.room.encrypted' && !ev.isDecryptionFailure()) ev.once(MatrixEventEvent.Decrypted, go); else go();
}
async function notifSettings(){
  const c = notifCfg();
  const onoff = v => v ? 'Включено' : 'Выключено';
  const v = await modal({title:'Уведомления', html:`<div class="info-row"><small>Уведомления</small>${onoff(c.on)}</div><div class="info-row"><small>Текст сообщения в уведомлении</small>${onoff(c.preview)}</div><div class="info-row"><small>Звук</small>${onoff(c.sound)}</div>
    <p style="font-size:13px;margin-top:10px">Если уведомления не появляются, разрешите их для «Ласточки» в системе: macOS — Системные настройки → Уведомления; Windows — Параметры → Система → Уведомления.</p>`,
    buttons:[{label:c.on ? 'Выключить уведомления' : 'Включить уведомления', value:'on'}, {label:c.preview ? 'Скрывать текст' : 'Показывать текст', value:'preview'}, {label:c.sound ? 'Без звука' : 'Со звуком', value:'sound'}, {label:'Проверить', value:'test'}, {label:'Закрыть'}]});
  if (!v) return;
  if (v === 'test') { sysNotify({title:'Ласточка', body:'Уведомления работают ✓', tag:'test'}); return notifSettings(); }
  try { localStorage.setItem(LS_NOTIF, JSON.stringify({...c, [v]:!c[v]})); } catch {}
  notifSettings();
}

/* ---------- session storage ---------- */
// В приложении сессия и ключ базы шифрования хранятся через Связку ключей macOS / DPAPI Windows,
// как в Element Desktop. В браузере (npm run dev) — запасной вариант через localStorage.
const SECURE = window.desktop?.secure || null;
S.secure = {available:false, backend:'', legacy:false};
async function loadSession(){
  if (SECURE) {
    try { S.secure = {...S.secure, ...(await SECURE.info())}; } catch {}
    if (S.secure.available) {
      let s = null; try { s = await SECURE.getSession(); } catch {}
      if (s?.token) { S.secure.legacy = !!s.legacy; return s; }
      let old = null; try { old = JSON.parse(localStorage.getItem(LS_SESSION) || 'null'); } catch {}
      if (old?.token) {
        // Переход со старой версии: токен убираем из открытого хранилища,
        // но база ключей этого входа осталась незашифрованной — помечаем.
        const mig = {...old, legacy:true};
        await SECURE.setSession(mig); localStorage.removeItem(LS_SESSION);
        S.secure.legacy = true; return mig;
      }
      return null;
    }
  }
  try { return JSON.parse(localStorage.getItem(LS_SESSION) || 'null'); } catch { return null; }
}
async function saveSession(sess){
  if (SECURE && S.secure.available) { await SECURE.setSession(sess); localStorage.removeItem(LS_SESSION); }
  else localStorage.setItem(LS_SESSION, JSON.stringify(sess));
}
async function clearSession(){
  localStorage.removeItem(LS_SESSION);
  if (SECURE) { try { await SECURE.clear(); } catch {} }
}
async function storageKeyFor(sess){
  if (!SECURE || !S.secure.available || sess.legacy) return null;
  const b64 = await SECURE.storageKey(sess.userId, sess.deviceId);
  return Uint8Array.from(atob(b64), c => c.charCodeAt(0));
}

// Обход ошибки matrix-js-sdk 37: запрос на подтверждение собеседника уходит в чат
// без поля msgtype, и Synapse отвечает 400 «'msgtype' not in content».
// Дополняем содержимое до корректного m.key.verification.request перед отправкой.
function patchVerificationDM(){
  const rc = crypto_();
  if (!rc || typeof rc.sendVerificationRequestContent !== 'function' || rc.__lastochkaPatched) return;
  const orig = rc.sendVerificationRequestContent.bind(rc);
  rc.sendVerificationRequestContent = (roomId, content) => {
    let c = content;
    try { if (typeof c === 'string') c = JSON.parse(c); } catch { return orig(roomId, content); }
    if (c && typeof c === 'object' && !c.msgtype) {
      c = {msgtype:'m.key.verification.request', body:(S.me.name || S.userId) + ' хочет подтвердить вашу личность. Ваше приложение не поддерживает подтверждение — откройте Element или Ласточку.', ...c};
    }
    return orig(roomId, c);
  };
  rc.__lastochkaPatched = true;
}

/* ---------- client lifecycle ---------- */
function wipeCryptoDB(){
  return Promise.all(['::matrix-sdk-crypto', '::matrix-sdk-crypto-meta'].map(s => new Promise(r => {
    try { const q = indexedDB.deleteDatabase(DB_PREFIX + s); q.onsuccess = q.onerror = q.onblocked = () => r(); } catch { r(); }
  })));
}
function readDM(){ S.dm = S.client.getAccountData('m.direct')?.getContent() || {}; }
function setOnline(v){ if (S.online === v) return; S.online = v; $('#conn').hidden = v; }
function bindClient(c){
  c.on(ClientEvent.Sync, (state, _prev, data) => {
    if (state === 'PREPARED') { S.initialDone = true; readDM(); schedule(); refreshCryptoState(); hideSplash(); }
    if (state === 'ERROR' || state === 'RECONNECTING') setTimeout(hideSplash, 2500);
    if (state === 'PREPARED' || state === 'SYNCING') setOnline(true);
    if (state === 'ERROR' || state === 'RECONNECTING') setOnline(false);
    if (data?.error?.errcode === 'M_UNKNOWN_TOKEN') forcedLogout();
  });
  c.on(sdk.HttpApiEvent?.SessionLoggedOut ?? 'Session.logged_out', forcedLogout);
  c.on(RoomEvent.Timeline, (ev, room, toStart, _removed, data) => {
    if (!room) return;
    scheduleFor(room.roomId);
    if (!toStart && data?.liveEvent && S.initialDone) maybeNotify(ev, room);
  });
  c.on(MatrixEventEvent.Decrypted, ev => { scheduleFor(ev.getRoomId()); if (ev.isDecryptionFailure?.()) onUTD(); });
  c.on(RoomEvent.LocalEchoUpdated, (_ev, room) => room && scheduleFor(room.roomId));
  c.on(RoomEvent.Redaction, (_ev, room) => room && scheduleFor(room.roomId));
  c.on(RoomEvent.Receipt, (_ev, room) => room && scheduleFor(room.roomId));
  c.on(RoomEvent.TimelineReset, room => { if (room) { uiOf(room.roomId).reachedStart = false; scheduleFor(room.roomId); } });
  c.on(RoomEvent.Name, room => scheduleFor(room.roomId));
  c.on(RoomEvent.MyMembership, (room, mem) => { if ((mem === 'leave' || mem === 'ban') && S.current === room.roomId) closeChat(); schedule(); });
  if (RoomEvent.UnreadNotifications) c.on(RoomEvent.UnreadNotifications, () => schedule(true, false));
  c.on(ClientEvent.Room, () => schedule(true, false));
  c.on(ClientEvent.AccountData, ev => {
    if (ev.getType() === 'm.direct') { readDM(); schedule(); }
    if (ev.getType() === 'im.ponies.user_emotes' && !$('#picker').hidden && S.picker?.tab === 'stickers') renderPicker();
  });
  c.on('Call.incoming', onIncomingCall);
  c.on(RoomMemberEvent.Typing, (_ev, member) => scheduleFor(member.roomId));
  if (sdk.RoomStateEvent?.Events) c.on(sdk.RoomStateEvent.Events, ev => scheduleFor(ev.getRoomId()));
  c.on('Room.tags', () => schedule());
  c.on(ClientEvent.AccountData, ev => { if (ev.getType() === 'm.push_rules') schedule(); });
  const CE = CA.CryptoEvent || {};
  c.on(CE.VerificationRequestReceived ?? 'crypto.verificationRequestReceived', onIncomingVerification);
  for (const name of [CE.UserTrustStatusChanged ?? 'userTrustStatusChanged', CE.KeysChanged ?? 'crossSigning.keysChanged', CE.DevicesUpdated ?? 'crypto.devicesUpdated']) {
    c.on(name, () => { clearTimeout(bindClient.t); bindClient.t = setTimeout(() => { refreshCryptoState(); renderIdBar(true); }, 800); });
  }
}
let loggingOut = false;
async function forcedLogout(){
  if (loggingOut) return; loggingOut = true;
  try { S.client?.stopClient(); } catch {}
  try { await S.client?.clearStores(); } catch {}
  await wipeCryptoDB(); await clearSession();
  toast('Сессия завершена, войдите снова');
  setTimeout(() => location.reload(), 1500);
}
async function logout(){
  let backup = null; try { backup = await crypto_()?.getActiveSessionBackupVersion?.(); } catch {}
  if (crypto_() && !backup) {
    const v = await modal({title:'Не потеряйте переписку', html:'<p><b>Резервная копия ключей не включена.</b> Если выйти сейчас, зашифрованные сообщения на этом устройстве будет нечем расшифровать. Сначала включите резервную копию в «Шифрование и ключи» или сохраните ключи в файл.</p>', buttons:[{label:'Отмена'}, {label:'Сохранить ключи в файл', value:'export'}, {label:'Всё равно выйти', value:'out', danger:true}]});
    if (v === 'export') return exportKeys();
    if (v !== 'out') return;
  } else {
    const ok0 = await modal({title:'Выйти из аккаунта?', html:'<p>Ключи шифрования этого устройства будут удалены. Старую переписку потом можно будет вернуть ключом восстановления.</p>', buttons:[{label:'Отмена'}, {label:'Выйти', value:true, danger:true}]});
    if (!ok0) return;
  }
  return doLogout();
}
async function doLogout(){
  loggingOut = true;
  try { await S.client.logout(true); } catch {}
  try { await S.client.clearStores(); } catch {}
  await wipeCryptoDB();
  await clearSession();
  try { for (const k of Object.keys(localStorage)) if (/^lastochka\.stk\./.test(k)) localStorage.removeItem(k); } catch {}
  location.reload();
}
async function start(sess){
  Object.assign(S, sess);
  $('#login').hidden = true; $('#app').hidden = false;
  splashText('Открываем хранилище ключей…');
  const client = sdk.createClient({baseUrl:S.hs, accessToken:S.token, userId:S.userId, deviceId:S.deviceId, cryptoCallbacks, timelineSupport:true,
    // Звонки — как в Element Classic (createMatrixClient.ts): P2P разрешён, резервный STUN matrix.org
    // только если сервер не выдал TURN, и заранее собираем до 20 маршрутов при звонке.
    forceTURN:false, fallbackICEServerAllowed:true, iceCandidatePoolSize:20});
  S.client = client;
  patchTurnServers(client);
  patchMedia(client);
  renderList();
  // Ключ локального хранилища шифрования — из Связки ключей / DPAPI. Если доступ не дали,
  // НЕ запускаемся без него (иначе хранилище нельзя открыть и устройство «забудет» подтверждение).
  let storageKey = null;
  for (;;) {
    try { storageKey = await storageKeyFor(sess); break; }
    catch (e) {
      const v = await modal({title:'Нет доступа к ключам', html:'<p>Ласточке нужен доступ к записи «Ласточка Safe Storage» в Связке ключей — там хранится ключ от вашей зашифрованной переписки на этом устройстве. Когда macOS спросит, введите пароль от Mac и нажмите «Разрешать всегда».</p>', buttons:[{label:'Выйти из аккаунта', value:'out', danger:true}, {label:'Повторить', value:'retry'}]});
      if (v === 'out') { await clearSession(); location.reload(); return; }
    }
  }
  const opts = {cryptoDatabasePrefix:DB_PREFIX, ...(storageKey ? {storageKey} : {})};
  S.secure.storeEncrypted = !!storageKey;
  try {
    await client.initRustCrypto(opts);
  } catch (e) {
    console.error(e);
    // Хранилище этого устройства не открывается. Создавать новые ключи под тем же устройством нельзя —
    // сервер их не примет и подтверждение «зависнет». Как в Element: входим заново как новое устройство.
    try { client.stopClient(); } catch {}
    await modal({title:'Нужно войти заново', html:'<p>Не удалось открыть локальное хранилище ключей этого устройства. Войдите ещё раз и подтвердите вход ключом восстановления — переписка восстановится из резервной копии.</p><p style="font-size:13px">Подробности: ' + esc(e.message || e) + '</p>', buttons:[{label:'Войти заново', value:true}]});
    try { await client.logout(true); } catch {}
    await wipeCryptoDB(); await clearSession(); location.reload();
    return;
  }
  applyStrict();
  patchVerificationDM();
  bindClient(client);
  client.getProfileInfo(S.userId).then(p => { S.me = {name:p.displayname || '', avatar:p.avatar_url || ''}; }).catch(() => {});
  splashText('Синхронизация чатов…');
  await client.startClient({initialSyncLimit:30, lazyLoadMembers:true});
}

/* ---------- login ---------- */
async function discover(input){
  let hs = input.trim().replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(hs)) hs = 'https://' + hs;
  try {
    const r = await fetch(hs + '/.well-known/matrix/client');
    if (r.ok) { const j = await r.json(); const b = j['m.homeserver']?.base_url; if (b) return b.replace(/\/+$/, ''); }
  } catch {}
  return hs;
}
$('#login-form').addEventListener('submit', async e => {
  e.preventDefault();
  const btn = $('#l-btn'), err = $('#l-err');
  btn.disabled = true; btn.textContent = 'Вход…'; err.hidden = true;
  try {
    let user = $('#l-user').value.trim(), srvIn = $('#l-server').value.trim();
    const mx = /^@?([^:@\s]+):(\S+)$/.exec(user);
    if (mx) { user = mx[1]; if (!srvIn) { srvIn = mx[2]; $('#l-server').value = srvIn; } }
    if (!srvIn) throw new Error('Укажите адрес сервера');
    const hs = await discover(srvIn);
    const ver = await fetch(hs + '/_matrix/client/versions').then(r => r.ok ? r.json() : null).catch(() => null);
    if (!ver?.versions) throw new Error('По адресу «' + srvIn + '» не найден сервер Matrix. Проверьте адрес.');
    if (/^http:\/\//i.test(hs) && !/^http:\/\/(localhost|127\.0\.0\.1)(:|\/|$)/i.test(hs)) throw new Error('Разрешено только защищённое подключение (https://)');
    const r = await fetch(hs + '/_matrix/client/v3/login', {method:'POST', headers:{'Content-Type':'application/json'},
      body:JSON.stringify({type:'m.login.password', identifier:{type:'m.id.user', user}, password:$('#l-pass').value, initial_device_display_name:'Ласточка (' + (/Mac/i.test(navigator.platform) ? 'macOS' : /Win/i.test(navigator.platform) ? 'Windows' : 'веб') + ')'})});
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(j.errcode === 'M_FORBIDDEN' ? 'Неверный логин или пароль' : j.errcode === 'M_LIMIT_EXCEEDED' ? 'Слишком много попыток, подождите немного' : (j.error || 'Ошибка ' + r.status));
    let base = hs; const wk = j.well_known?.['m.homeserver']?.base_url; if (wk) base = wk.replace(/\/+$/, '');
    const sess = {hs:base, token:j.access_token, userId:j.user_id, deviceId:j.device_id};
    await wipeCryptoDB();
    await saveSession(sess);
    try { localStorage.setItem('lastochka.server', srvIn); } catch {}
    if ('Notification' in window && Notification.permission === 'default') Notification.requestPermission().catch(() => {});
    start(sess);
  } catch (ex) {
    err.textContent = ex instanceof TypeError ? 'Сервер недоступен. Проверьте адрес и подключение.' : ex.message;
    err.hidden = false;
  } finally { btn.disabled = false; btn.textContent = 'Войти'; }
});
(async function boot(){
  const sess = await loadSession();
  updateLockBtn();
  if (sess?.token && sess.deviceId) { if (lockCfg()) lockApp(); start(sess); } else {
    let last = ''; try { last = localStorage.getItem('lastochka.server') || ''; } catch {}
    $('#l-server').value = last;
    $('#login').hidden = false; hideSplash(); (last ? $('#l-user') : $('#l-server')).focus();
  }
})();
