// «Ласточка» — оболочка десктоп-приложения.
// Защита по образцу Element Desktop:
//  • ключ хранилища шифрования и токен входа лежат зашифрованными через
//    Связку ключей macOS / DPAPI Windows (Electron safeStorage);
//  • песочница, contextIsolation, CSP, запрет webview, новых окон и навигации;
//  • DevTools выключены в собранном приложении;
//  • Electron Fuses (в package.json): нельзя запустить как Node, подключить
//    отладчик или подменить код приложения внутри .app/.exe.
const { app, BrowserWindow, protocol, shell, nativeTheme, session, systemPreferences,
  Notification, powerMonitor, safeStorage, ipcMain, Tray, Menu, nativeImage } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const crypto = require('node:crypto');

const APP_NAME = 'Ласточка';
app.setName(APP_NAME);
app.setPath('userData', path.join(app.getPath('appData'), 'Lastochka'));
app.enableSandbox();
if (process.platform === 'win32') app.setAppUserModelId('app.lastochka.desktop');

protocol.registerSchemesAsPrivileged([
  { scheme: 'app', privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true, stream: true } },
]);

const DIST = path.join(__dirname, '..', 'dist');
const ORIGIN = 'app://bundle';
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.wasm': 'application/wasm', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.json': 'application/json', '.ico': 'image/x-icon', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf',
};
const CSP = [
  "default-src 'self'",
  "script-src 'self' 'wasm-unsafe-eval'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' blob: data:",
  "media-src 'self' blob:",
  "connect-src 'self' blob: https: wss:",
  "font-src 'self' data:",
  "worker-src 'self' blob:",
  "object-src 'none'",
  "frame-src 'none'",
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "form-action 'none'",
].join('; ');

let win = null;
let tray = null;
let quitting = false;   // true — выходим по-настоящему (меню «Выйти», ⌘Q, выключение)

function showWindow() {
  if (!win) { createWindow(); return; }
  if (win.isMinimized()) win.restore();
  win.show(); win.focus();
}
// Значок в трее (Windows): приложение продолжает работать после закрытия окна —
// приходят сообщения и звонки, как в Telegram. На macOS для этого есть Dock.
function setupTray() {
  if (process.platform === 'darwin' || tray) return;
  const icon = nativeImage.createFromPath(path.join(__dirname, '..', 'build', 'icon.ico'));
  tray = new Tray(icon.isEmpty() ? nativeImage.createFromPath(path.join(__dirname, '..', 'build', 'icon.png')).resize({ width: 16, height: 16 }) : icon);
  tray.setToolTip(APP_NAME);
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Открыть Ласточку', click: showWindow },
    { type: 'separator' },
    { label: 'Выйти', click: () => { quitting = true; app.quit(); } },
  ]));
  tray.on('click', showWindow);
}
let lastUnread = 0;

/* ---------- защищённое хранилище (safeStorage) ---------- */
const SEC_FILE = () => path.join(app.getPath('userData'), 'secure-store.json');
function readSec() { try { return JSON.parse(fs.readFileSync(SEC_FILE(), 'utf8')); } catch { return {}; } }
function writeSec(o) {
  const tmp = SEC_FILE() + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(o), { mode: 0o600 });
  fs.renameSync(tmp, SEC_FILE());
}
const seal = s => safeStorage.encryptString(s).toString('base64');
const unseal = b => safeStorage.decryptString(Buffer.from(b, 'base64'));
function fromApp(e) {
  const url = e.senderFrame?.url || '';
  if (!url.startsWith(ORIGIN + '/')) throw new Error('Запрещено');
  if (!safeStorage.isEncryptionAvailable()) throw new Error('Системное хранилище ключей недоступно');
}
const str = (v, max = 4096) => typeof v === 'string' && v.length > 0 && v.length <= max;
function setupSecureIpc() {
  // обновления через GitHub Releases (с проверкой подписи разработчика)
  require('./updater.cjs')({
    fromApp: e => { const url = e.senderFrame?.url || ''; if (!url.startsWith(ORIGIN + '/')) throw new Error('Запрещено'); },
    getWin: () => win,
    quit: () => { quitting = true; app.quit(); },
  });
  ipcMain.handle('secure:info', () => ({
    available: safeStorage.isEncryptionAvailable(),
    backend: process.platform === 'darwin' ? 'Связка ключей macOS' : process.platform === 'win32' ? 'Windows DPAPI' : (safeStorage.getSelectedStorageBackend?.() || 'linux'),
  }));
  ipcMain.handle('secure:getSession', e => {
    fromApp(e);
    const o = readSec();
    if (!o.session) return null;
    try { return JSON.parse(unseal(o.session)); } catch { return null; }
  });
  ipcMain.handle('secure:setSession', (e, s) => {
    fromApp(e);
    if (!s || !str(s.hs) || !str(s.token) || !str(s.userId, 512) || !str(s.deviceId, 512) || !/^https?:\/\//.test(s.hs)) throw new Error('Некорректная сессия');
    const o = readSec();
    o.session = seal(JSON.stringify({ hs: s.hs, token: s.token, userId: s.userId, deviceId: s.deviceId, legacy: !!s.legacy }));
    writeSec(o);
    return true;
  });
  // Системные уведомления (Центр уведомлений macOS / уведомления Windows).
  const shown = new Map(); // держим ссылки, иначе клик по уведомлению может потеряться
  ipcMain.on('notify:show', (e, n) => {
    if (!(e.senderFrame?.url || '').startsWith(ORIGIN + '/') || !Notification.isSupported() || !n) return;
    const tag = String(n.tag || '').slice(0, 200);
    shown.get(tag)?.close();
    const note = new Notification({
      title: String(n.title || APP_NAME).slice(0, 200),
      body: String(n.body || '').slice(0, 500),
      silent: !!n.silent,
      urgency: n.urgent ? 'critical' : 'normal',
      timeoutType: n.urgent ? 'never' : 'default',
    });
    note.on('click', () => { showWindow(); win?.webContents.send('notify:click', tag); shown.delete(tag); });
    note.on('close', () => { if (shown.get(tag) === note) shown.delete(tag); });
    shown.set(tag, note);
    note.show();
  });
  ipcMain.on('notify:clear', (e, tag) => { if ((e.senderFrame?.url || '').startsWith(ORIGIN + '/')) { shown.get(tag)?.close(); shown.delete(tag); } });
  // Защита от снимков экрана и записи (macOS и Windows): окно на скриншотах выглядит пустым
  ipcMain.on('win:protect', (e, on) => {
    if (!(e.senderFrame?.url || '').startsWith(ORIGIN + '/')) return;
    try { win?.setContentProtection(!!on); } catch {}
  });
  ipcMain.on('win:titlebar', (e, color, symbol) => {
    if (!(e.senderFrame?.url || '').startsWith(ORIGIN + '/') || process.platform !== 'win32') return;
    const ok = v => typeof v === 'string' && /^#[0-9a-f]{3,8}$/i.test(v);
    if (ok(color) && ok(symbol)) try { win?.setTitleBarOverlay({ color, symbolColor: symbol, height: 32 }); } catch {}
  });
  ipcMain.on('win:show', e => { if ((e.senderFrame?.url || '').startsWith(ORIGIN + '/')) showWindow(); });
  // Локальный посредник для звонков: модуль звонков (WebRTC) на macOS не может достучаться
  // до сервера звонков через VPN, а само приложение может. Поэтому WebRTC подключается к
  // TURN по адресу 127.0.0.1, а приложение пересылает пакеты на настоящий сервер.
  // Принимаем пакеты только с адресов этого компьютера и пересылаем только на указанный сервер звонков.
  const proxies = new Map();
  // Некоторые серверы звонков отвечают на Allocate «успехом» без поля XOR-MAPPED-ADDRESS,
  // а модуль звонков Chromium такой ответ молча отбрасывает. Дописываем поле сами
  // (только в неподписанные ответы — подписанный ответ менять нельзя и не нужно).
  const CRC = (() => { const t = new Int32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c; } return t; })();
  const crc32 = b => { let c = -1; for (let i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 0xff] ^ (c >>> 8); return (c ^ -1) >>> 0; };
  const fixAllocate = (msg, addr, cport) => {
    if (msg.length < 20 || (msg[0] >> 6) !== 0 || msg.readUInt32BE(4) !== 0x2112A442) return msg;
    const t = msg.readUInt16BE(0), len = msg.readUInt16BE(2);
    const m = (t & 0x000F) | ((t & 0x00E0) >> 1) | ((t & 0x3E00) >> 2), cls = ((t & 0x0100) >> 7) | ((t & 0x0010) >> 4);
    if (m !== 3 || cls !== 2 || msg.length < 20 + len) return msg;
    let j = 20, fpAt = -1, hasMapped = false, hasMI = false;
    while (j + 4 <= 20 + len) {
      const at = msg.readUInt16BE(j), al = msg.readUInt16BE(j + 2);
      if (at === 0x0020) hasMapped = true;
      if (at === 0x0008 || at === 0x001C) hasMI = true;
      if (at === 0x8028) fpAt = j;
      j += 4 + al + ((4 - al % 4) % 4);
    }
    const a = String(addr || '').replace(/^::ffff:/, '');
    if (hasMapped || hasMI || !/^\d+\.\d+\.\d+\.\d+$/.test(a)) return msg;
    const body = msg.subarray(0, fpAt >= 0 ? fpAt : 20 + len);
    const x = Buffer.alloc(12);
    x.writeUInt16BE(0x0020, 0); x.writeUInt16BE(8, 2); x[4] = 0; x[5] = 1;
    x.writeUInt16BE((cport ^ 0x2112) & 0xffff, 6);
    a.split('.').forEach((o, k) => { x[8 + k] = (+o) ^ [0x21, 0x12, 0xA4, 0x42][k]; });
    let out = Buffer.concat([body, x]);
    if (fpAt >= 0) {
      out.writeUInt16BE(out.length - 20 + 8, 2);
      const fp = Buffer.alloc(8); fp.writeUInt16BE(0x8028, 0); fp.writeUInt16BE(4, 2);
      fp.writeUInt32BE((crc32(out) ^ 0x5354554e) >>> 0, 4);
      out = Buffer.concat([out, fp]);
    } else out.writeUInt16BE(out.length - 20, 2);
    pstat.fixed = (pstat.fixed || 0) + 1;
    return out;
  };
  // ---- «подпись» ответов сервера звонков ----
  // Сервер выдаёт ретранслятор без проверки логина и не подписывает ответы (нет MESSAGE-INTEGRITY),
  // а модуль звонков Chromium неподписанные «успехи» молча выбрасывает. Посредник берёт проверку
  // на себя: просит у модуля звонков логин (401 + REALM/NONCE), убирает подпись из запроса к серверу
  // и подписывает ответ сервера тем же паролем TURN, который выдал сервер Matrix.
  const SHIM_REALM = 'lastochka';
  const stunParse = b => {
    if (b.length < 20 || (b[0] >> 6) !== 0 || b.readUInt32BE(4) !== 0x2112A442) return null;
    const t = b.readUInt16BE(0), len = b.readUInt16BE(2);
    if (b.length < 20 + len) return null;
    const method = (t & 0x000F) | ((t & 0x00E0) >> 1) | ((t & 0x3E00) >> 2), cls = ((t & 0x0100) >> 7) | ((t & 0x0010) >> 4);
    const attrs = []; let j = 20;
    while (j + 4 <= 20 + len) { const at = b.readUInt16BE(j), al = b.readUInt16BE(j + 2); attrs.push({t:at, v:b.subarray(j + 4, j + 4 + al)}); j += 4 + al + ((4 - al % 4) % 4); }
    return {method, cls, txid:b.subarray(8, 20), attrs};
  };
  const stunType = (m, c) => (m & 0x000F) | ((m & 0x0070) << 1) | ((m & 0x0F80) << 2) | ((c & 1) << 4) | ((c & 2) << 7);
  const stunBuild = (method, cls, txid, attrs, key) => {
    const parts = [];
    for (const a of attrs) { const h = Buffer.alloc(4); h.writeUInt16BE(a.t, 0); h.writeUInt16BE(a.v.length, 2); parts.push(h, a.v, Buffer.alloc((4 - a.v.length % 4) % 4)); }
    let body = Buffer.concat(parts);
    const head = Buffer.alloc(20); head.writeUInt16BE(stunType(method, cls), 0); head.writeUInt32BE(0x2112A442, 4); txid.copy(head, 8);
    let msg;
    if (key) {
      head.writeUInt16BE(body.length + 24, 2);
      const mac = crypto.createHmac('sha1', key).update(Buffer.concat([head, body])).digest();
      const mi = Buffer.alloc(4); mi.writeUInt16BE(0x0008, 0); mi.writeUInt16BE(20, 2);
      msg = Buffer.concat([head, body, mi, mac]);
    } else { head.writeUInt16BE(body.length, 2); msg = Buffer.concat([head, body]); }
    msg.writeUInt16BE(msg.length - 20 + 8, 2);
    const fp = Buffer.alloc(8); fp.writeUInt16BE(0x8028, 0); fp.writeUInt16BE(4, 2); fp.writeUInt32BE((crc32(msg) ^ 0x5354554e) >>> 0, 4);
    return Buffer.concat([msg, fp]);
  };
  const AUTH_ATTRS = new Set([0x0006, 0x0008, 0x001C, 0x0014, 0x0015, 0x8028]);
  // одно соединение модуля звонков: обработка запроса (вверх) и ответа (вниз)
  const makeShim = (P) => {
    const st = {user:'', nonce:crypto.randomBytes(12).toString('hex')};
    const keyFor = u => { const pass = P.creds.get(u); return pass == null ? null : crypto.createHash('md5').update(`${u}:${SHIM_REALM}:${pass}`).digest(); };
    return {
      up(msg, reply, forward) {
        const m = stunParse(msg);
        if (!m || m.cls !== 0) return forward(msg);
        const userAttr = m.attrs.find(a => a.t === 0x0006);
        const hasMI = m.attrs.some(a => a.t === 0x0008);
        if (!hasMI) {
          if (m.method === 3 && P.creds.size) {  // Allocate без логина — просим логин, как настоящий сервер
            const err = Buffer.concat([Buffer.from([0, 0, 4, 1]), Buffer.from('Unauthorized')]);
            pstat.shim = (pstat.shim || 0) + 1;
            return reply(stunBuild(3, 3, m.txid, [{t:0x0009, v:err}, {t:0x0014, v:Buffer.from(SHIM_REALM)}, {t:0x0015, v:Buffer.from(st.nonce)}]));
          }
          return forward(msg);
        }
        if (userAttr) st.user = userAttr.v.toString('utf8');
        // к серверу — без подписи (он её не проверяет)
        forward(stunBuild(m.method, m.cls, m.txid, m.attrs.filter(a => !AUTH_ATTRS.has(a.t))));
      },
      down(msg, send) {
        const m = stunParse(msg);
        if (!m || (m.cls !== 2 && m.cls !== 3) || !st.user) return send(msg);
        const key = keyFor(st.user);
        if (!key) return send(msg);
        pstat.signed = (pstat.signed || 0) + 1;
        send(stunBuild(m.method, m.cls, m.txid, m.attrs.filter(a => !AUTH_ATTRS.has(a.t)), key));
      },
    };
  };
  // универсальная нарезка TCP-потока на кадры STUN / ChannelData
  const frames = (onFrame) => {
    let buf = Buffer.alloc(0);
    return d => {
      buf = buf.length ? Buffer.concat([buf, d]) : d;
      while (buf.length >= 4) {
        const kind = buf[0] >> 6;
        let total;
        if (kind === 0) { if (buf.length < 20) break; total = 20 + buf.readUInt16BE(2); }
        else if (kind === 1) { const l = buf.readUInt16BE(2); total = 4 + l + ((4 - l % 4) % 4); }
        else { onFrame(buf); buf = Buffer.alloc(0); break; }
        if (buf.length < total) break;
        const one = buf.subarray(0, total); buf = buf.subarray(total);
        onFrame(one);
      }
    };
  };
  // разбор потока TCP на отдельные сообщения STUN / ChannelData
  const tcpFramer = (onMsg) => {
    let buf = Buffer.alloc(0);
    return d => {
      buf = buf.length ? Buffer.concat([buf, d]) : d;
      const out = [];
      while (buf.length >= 4) {
        const kind = buf[0] >> 6;
        let total;
        if (kind === 0) { if (buf.length < 20) break; total = 20 + buf.readUInt16BE(2); }
        else if (kind === 1) { const l = buf.readUInt16BE(2); total = 4 + l + ((4 - l % 4) % 4); }
        else { out.push(buf); buf = Buffer.alloc(0); break; }
        if (buf.length < total) break;
        const one = buf.subarray(0, total); buf = buf.subarray(total);
        out.push(kind === 0 ? onMsg(one) : one);
      }
      return out.length ? Buffer.concat(out) : null;
    };
  };
  const pstat = {udpIn:0, udpUp:0, udpDown:0, tcpConn:0, tcpUp:0, tcpDown:0, err:'', log:[]};
  // Расшифровка заголовков STUN/TURN для диагностики: какой запрос ушёл и что ответил сервер
  const STUN_M = {1:'Binding', 3:'Allocate', 4:'Refresh', 6:'Send', 7:'Data', 8:'CreatePermission', 9:'ChannelBind'};
  const stunLog = (dir, buf) => {
    let i = 0;
    while (i + 20 <= buf.length) {
      const t = buf.readUInt16BE(i), len = buf.readUInt16BE(i + 2);
      if (buf.readUInt32BE(i + 4) !== 0x2112A442) break;
      const m = (t & 0x000F) | ((t & 0x00E0) >> 1) | ((t & 0x3E00) >> 2), cls = ((t & 0x0100) >> 7) | ((t & 0x0010) >> 4);
      let txt = (dir === 'up' ? '→ ' : '← ') + (STUN_M[m] || 'метод ' + m) + ' ' + ['запрос', 'индикация', 'успех', 'ошибка'][cls];
      let j = i + 20; const attrs = [];
      while (j + 4 <= i + 20 + len && j + 4 <= buf.length) {
        const at = buf.readUInt16BE(j), al = buf.readUInt16BE(j + 2);
        if (at === 0x0009 && al >= 4) txt += ' ' + (buf[j + 6] * 100 + buf[j + 7]) + ' ' + buf.subarray(j + 8, j + 4 + al).toString('utf8').slice(0, 60);
        if (at === 0x0016 && al >= 8) txt += ' relay ' + [...buf.subarray(j + 8, j + 12)].map((b, k) => b ^ [0x21, 0x12, 0xA4, 0x42][k]).join('.');
        if (at === 0x0020 && al >= 8) txt += ' mapped ' + [...buf.subarray(j + 8, j + 12)].map((b, k) => b ^ [0x21, 0x12, 0xA4, 0x42][k]).join('.');
        if (at === 0x8022) txt += ' [' + buf.subarray(j + 4, j + 4 + al).toString('utf8').slice(0, 40) + ']';
        if (at === 0x0006) txt += ' user';
        if (at === 0x0008) txt += ' MI';
        attrs.push(at.toString(16));
        j += 4 + al + ((4 - al % 4) % 4);
      }
      txt += ' {' + attrs.join(',') + '} ' + (20 + len) + 'б';
      pstat.log.push(txt); if (pstat.log.length > 40) pstat.log.shift();
      i += 20 + len + ((4 - len % 4) % 4);
    }
  };
  ipcMain.handle('turn:proxy', async (e, host, port, user, pass) => {
    fromApp(e);
    if (!str(host, 255) || !Number.isInteger(port) || port <= 0 || port > 65535) throw new Error('Некорректные данные');
    const key = host + ':' + port;
    const addCred = P => { if (str(user, 512) && typeof pass === 'string' && pass.length < 512) { P.creds.set(user, pass); if (P.creds.size > 8) P.creds.delete(P.creds.keys().next().value); } };
    if (proxies.has(key)) { const P = proxies.get(key); addCred(P); return {...P.ports, addrs:P.ports.addrs}; }
    const P = {creds:new Map()}; addCred(P);
    const dgram = require('node:dgram'), net = require('node:net'), dns = require('node:dns').promises;
    const ip = net.isIP(host) ? host : (await dns.lookup(host, {family:4})).address;
    const os = require('node:os');
    const own = a => { a = String(a || '').replace(/^::ffff:/, ''); if (a === '127.0.0.1' || a === '::1') return true; return Object.values(os.networkInterfaces()).flat().some(i => i && i.address === a); };
    // UDP: на каждый локальный сокет WebRTC — свой сокет к серверу (TURN различает клиентов по адресу)
    const udp = dgram.createSocket('udp4'), clients = new Map();
    udp.on('message', (msg, r) => {
      pstat.udpIn++;
      if (!own(r.address)) { pstat.err = 'чужой адрес ' + r.address; return; }
      const k = r.address + ':' + r.port;
      let c = clients.get(k);
      if (!c) {
        const up = dgram.createSocket('udp4'), shim = makeShim(P);
        up.on('message', m => { pstat.udpDown++; stunLog('down', m); shim.down(m, out => udp.send(out, r.port, r.address)); });
        up.on('error', () => { try { up.close(); } catch {} clients.delete(k); });
        c = {up, shim}; clients.set(k, c);
      }
      c.last = Date.now();
      stunLog('up', msg);
      c.shim.up(msg, out => udp.send(out, r.port, r.address), out => c.up.send(out, port, ip, err => { if (err) pstat.err = err.code || err.message; else pstat.udpUp++; }));
    });
    udp.on('error', () => {});
    // на Windows — только 127.0.0.1, чтобы брандмауэр не спрашивал разрешение
    const LISTEN = process.platform === 'win32' ? '127.0.0.1' : '0.0.0.0';
    await new Promise(r => udp.bind(0, LISTEN, r));
    setInterval(() => { const t = Date.now() - 10 * 60e3; for (const [k, c] of clients) if (c.last < t) { try { c.up.close(); } catch {} clients.delete(k); } }, 60e3).unref();
    // TCP: простое перенаправление соединения
    const tcp = net.createServer(sock => {
      pstat.tcpConn++;
      if (!own(sock.remoteAddress)) { pstat.err = 'чужой адрес ' + sock.remoteAddress; return sock.destroy(); }
      const up = net.connect(port, ip);
      sock.setNoDelay(true); up.setNoDelay(true);
      const shim = makeShim(P);
      const fUp = frames(f => shim.up(f, out => sock.write(out), out => up.write(out)));
      const fDown = frames(f => shim.down(f, out => sock.write(out)));
      sock.on('data', d => { pstat.tcpUp += d.length; try { stunLog('up', d); } catch {} fUp(d); });
      up.on('data', d => { pstat.tcpDown += d.length; try { stunLog('down', d); } catch {} fDown(d); });
      const end = () => { sock.destroy(); up.destroy(); };
      sock.on('error', end); up.on('error', end); sock.on('close', end); up.on('close', end);
    });
    tcp.on('error', () => {});
    await new Promise(r => tcp.listen(0, LISTEN, r));
    const ports = {udp:udp.address().port, tcp:tcp.address().port, ip};
    // адреса этого компьютера: WebRTC привязывает сокеты к сетевому адаптеру (Wi-Fi),
    // поэтому посредник доступен по адресу каждого адаптера, а не только 127.0.0.1
    Object.defineProperty(ports, 'addrs', {enumerable:true, get:() => process.platform === 'win32' ? ['127.0.0.1'] : ['127.0.0.1', ...Object.values(os.networkInterfaces()).flat().filter(i => i && i.family === 'IPv4' && !i.internal).map(i => i.address)]});
    P.udp = udp; P.tcp = tcp; P.ports = ports;
    proxies.set(key, P);
    return {...ports, addrs:ports.addrs};
  });
  ipcMain.handle('turn:stats', (e, reset) => { fromApp(e); const r = {...pstat, log:[...pstat.log]}; if (reset) pstat.log = []; return r; });
  // Диагностика звонков: отвечает ли сервер TURN/STUN, если проверять из самого приложения (не из WebRTC).
  ipcMain.handle('net:probe', async (e, targets) => {
    fromApp(e);
    const dgram = require('node:dgram'), net = require('node:net'), dns = require('node:dns').promises;
    const list = (Array.isArray(targets) ? targets : []).slice(0, 8).filter(t => t && str(t.host, 255) && Number.isInteger(t.port) && t.port > 0 && t.port < 65536 && (t.proto === 'udp' || t.proto === 'tcp'));
    const req = () => { const b = Buffer.alloc(20); b.writeUInt16BE(1, 0); b.writeUInt32BE(0x2112A442, 4); crypto.randomBytes(12).copy(b, 8); return b; };
    const one = async t => {
      let ip = t.host;
      try { if (!net.isIP(ip)) ip = (await dns.lookup(ip, {family:4})).address; } catch (err) { return {...t, ok:false, err:'DNS: ' + err.code}; }
      return new Promise(res => {
        const fin = (ok, err) => { clearTimeout(timer); try { sock.close?.(); sock.destroy?.(); } catch {} res({...t, ip, ok, err}); };
        let sock;
        const timer = setTimeout(() => fin(false, 'нет ответа за 4 с'), 4000);
        if (t.proto === 'udp') {
          sock = dgram.createSocket('udp4');
          sock.on('message', () => fin(true));
          sock.on('error', err => fin(false, err.code || err.message));
          sock.send(req(), t.port, ip);
        } else {
          sock = net.connect(t.port, ip);
          sock.on('connect', () => sock.write(req()));
          sock.on('data', () => fin(true));
          sock.on('error', err => fin(false, err.code || err.message));
        }
      });
    };
    return Promise.all(list.map(one));
  });
  ipcMain.handle('secure:clear', e => { fromApp(e); writeSec({}); return true; });
  // 32-байтный ключ, которым Rust-криптография шифрует свою базу (как «pickle key» в Element).
  ipcMain.handle('secure:storageKey', (e, userId, deviceId) => {
    fromApp(e);
    if (!str(userId, 512) || !str(deviceId, 512)) throw new Error('Некорректные данные');
    const id = crypto.createHash('sha256').update(userId + '|' + deviceId).digest('hex');
    const o = readSec(); o.keys = o.keys || {};
    if (o.keys[id]) return unseal(o.keys[id]);
    const key = crypto.randomBytes(32).toString('base64');
    o.keys = { [id]: seal(key) }; // старые ключи прошлых входов не нужны
    writeSec(o);
    return key;
  });
}

/* ---------- окно ---------- */
function createWindow() {
  win = new BrowserWindow({
    width: 1100, height: 760, minWidth: 380, minHeight: 500,
    title: APP_NAME,
    autoHideMenuBar: true,
    // Windows: свой заголовок в цветах приложения, системные кнопки поверх него
    // macOS: «светофор» поверх своего заголовка со значком
    ...(process.platform === 'darwin' ? { titleBarStyle: 'hiddenInset', trafficLightPosition: { x: 14, y: 12 } } : {}),
    ...(process.platform === 'win32' ? { titleBarStyle: 'hidden', titleBarOverlay: { color: nativeTheme.shouldUseDarkColors ? '#212121' : '#ffffff', symbolColor: nativeTheme.shouldUseDarkColors ? '#ffffff' : '#000000', height: 32 } } : {}),
    icon: path.join(__dirname, '..', 'build', process.platform === 'win32' ? 'icon.ico' : 'icon.png'),
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#212121' : '#ffffff',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true, sandbox: true, nodeIntegration: false, nodeIntegrationInWorker: false,
      webviewTag: false, navigateOnDragDrop: false, safeDialogs: true, spellcheck: true,
      backgroundThrottling: false, // в фоне не замедляемся: сообщения, уведомления и звонки приходят сразу
      devTools: !app.isPackaged,
    },
  });
  win.on('page-title-updated', (_e, title) => {
    const m = /^\((\d+)\)/.exec(title);
    const n = m ? +m[1] : 0;
    app.dock?.setBadge(n ? String(n) : '');
    if (process.platform === 'win32' && n > lastUnread && !win.isFocused()) win.flashFrame(true);
    lastUnread = n;
  });
  win.on('focus', () => win.flashFrame(false));
  // Крестик не закрывает приложение, а прячет окно: оно работает в фоне.
  win.on('close', e => {
    if (quitting) return;
    e.preventDefault();
    if (process.platform === 'darwin' && win.isFullScreen()) { win.once('leave-full-screen', () => win.hide()); win.setFullScreen(false); }
    else win.hide();
  });
  win.on('closed', () => { win = null; });
  win.loadURL(ORIGIN + '/index.html');
}

function uniquePath(dir, name) {
  const safe = String(name || 'file').replace(/[\\/:*?"<>|\u0000-\u001f]+/g, '_') || 'file';
  const ext = path.extname(safe), base = safe.slice(0, safe.length - ext.length);
  let p = path.join(dir, safe), n = 1;
  while (fs.existsSync(p)) p = path.join(dir, `${base} (${n++})${ext}`);
  return p;
}

function setupSession() {
  const ses = session.defaultSession;
  ses.setPermissionRequestHandler((wc, permission, callback, details) => {
    if (!wc.getURL().startsWith(ORIGIN + '/')) return callback(false);
    if (permission === 'notifications') return callback(true);
    if (permission === 'media') {
      // Микрофон — для голосовых и звонков, камера — только для видеозвонков.
      const types = details.mediaTypes || [];
      if (process.platform !== 'darwin') return callback(true);
      const ask = [];
      if (types.includes('audio') || !types.length) ask.push(systemPreferences.askForMediaAccess('microphone'));
      if (types.includes('video')) ask.push(systemPreferences.askForMediaAccess('camera'));
      Promise.all(ask).then(r => callback(r.every(Boolean))).catch(() => callback(false));
      return;
    }
    if (permission === 'clipboard-sanitized-write') return callback(true);
    callback(false);
  });
  ses.setPermissionCheckHandler((wc, permission) => !!wc?.getURL().startsWith(ORIGIN + '/') && ['notifications', 'media', 'clipboard-sanitized-write'].includes(permission));
  ses.setDevicePermissionHandler(() => false);
  // Только современный TLS при подключении к серверу
  try { ses.setSSLConfig({ minVersion: 'tls1.2' }); } catch {}
  ses.on('will-download', (_e, item) => {
    const target = uniquePath(app.getPath('downloads'), item.getFilename());
    item.setSavePath(target);
    item.once('done', (_ev, state) => {
      if (state !== 'completed' || !Notification.isSupported()) return;
      const n = new Notification({ title: 'Файл сохранён', body: path.basename(target) });
      n.on('click', () => shell.showItemInFolder(target));
      n.show();
    });
  });
}

// Любое окно/вкладка: без webview, без новых окон, без перехода на внешние сайты.
app.on('web-contents-created', (_e, wc) => {
  wc.on('will-attach-webview', ev => ev.preventDefault());
  wc.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//i.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  const block = (ev, url) => {
    if (url.startsWith(ORIGIN + '/')) return;
    ev.preventDefault();
    if (/^https?:\/\//i.test(url)) shell.openExternal(url);
  };
  wc.on('will-navigate', block);
  wc.on('will-redirect', block);
});

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', showWindow);
  app.on('before-quit', () => { quitting = true; });

  app.whenReady().then(() => {
    protocol.handle('app', async req => {
      const u = new URL(req.url);
      if (u.host !== 'bundle') return new Response('Forbidden', { status: 403 });
      const file = path.normalize(path.join(DIST, decodeURIComponent(u.pathname)));
      if (!file.startsWith(DIST + path.sep)) return new Response('Forbidden', { status: 403 });
      try {
        const data = await fs.promises.readFile(file);
        const ext = path.extname(file).toLowerCase();
        const headers = { 'content-type': MIME[ext] || 'application/octet-stream', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' };
        if (ext === '.html') headers['content-security-policy'] = CSP;
        return new Response(data, { status: 200, headers });
      } catch {
        return new Response('Not found', { status: 404 });
      }
    });
    setupSecureIpc();
    setupSession();
    createWindow();
    const sysLock = () => win?.webContents.send('system-lock');
    powerMonitor.on('lock-screen', sysLock);
    powerMonitor.on('suspend', sysLock);
    setupTray();
    app.on('activate', showWindow);
  });

  app.on('window-all-closed', () => { /* остаёмся в фоне; выход — через меню, ⌘Q или трей */ });
}
