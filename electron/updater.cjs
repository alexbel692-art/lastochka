// Обновления Ласточки через GitHub Releases.
// Новая версия ставится, только если её файл подписан ключом разработчика (Ed25519).
// Публичная часть ключа зашита ниже; секретная хранится только у разработчика и в
// секретах GitHub Actions. Даже если кто-то получит доступ к репозиторию с релизами,
// подменённый файл без подписи не пройдёт проверку.
const { app, ipcMain, shell, net } = require('electron');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const RELEASES_REPO = 'alexbel692-art/lastochka';
const PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAt/kw3nU6I8XI9xvrdyCFpvd+w8gjfAALDSDl5BRRQgE=
-----END PUBLIC KEY-----`;

const cmpVer = (a, b) => {
  const pa = String(a).split(/[.-]/).map(n => parseInt(n, 10) || 0), pb = String(b).split(/[.-]/).map(n => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) { const d = (pa[i] || 0) - (pb[i] || 0); if (d) return d; }
  return 0;
};
const isPortable = () => process.platform === 'win32' && !!process.env.PORTABLE_EXECUTABLE_FILE;
// какой файл релиза подходит этому компьютеру
function pickAsset(assets){
  const names = assets.map(a => a.name);
  let re;
  if (process.platform === 'win32') re = isPortable() ? /-portable\.exe$/i : /^Lastochka-Setup-.*\.exe$/i;
  else if (process.platform === 'darwin') re = new RegExp(`-${process.arch}\\.dmg$`, 'i');
  else return null;
  const name = names.find(n => re.test(n));
  if (!name) return null;
  const file = assets.find(a => a.name === name), sig = assets.find(a => a.name === name + '.sig');
  return file && sig ? {file, sig} : null;
}
async function getJSON(url){
  const r = await net.fetch(url, { headers: { accept: 'application/vnd.github+json', 'user-agent': 'Lastochka-Updater' } });
  if (!r.ok) throw new Error('GitHub ответил ' + r.status);
  return r.json();
}
let pending = null;   // найденное обновление
let busy = false;

module.exports = function setupUpdater({ fromApp, getWin, quit }){
  ipcMain.handle('update:check', async e => {
    fromApp(e);
    const rel = await getJSON(`https://api.github.com/repos/${RELEASES_REPO}/releases/latest`);
    const version = String(rel.tag_name || '').replace(/^v/, '');
    const current = app.getVersion();
    if (!version || cmpVer(version, current) <= 0) { pending = null; return { upToDate: true, current }; }
    const pick = pickAsset(rel.assets || []);
    if (!pick) return { upToDate: true, current, note: 'Для этой системы файла нет' };
    pending = { version, ...pick };
    return { version, current, notes: String(rel.body || '').slice(0, 1500), size: pick.file.size, portable: isPortable(), platform: process.platform };
  });

  ipcMain.handle('update:install', async e => {
    fromApp(e);
    if (!pending) throw new Error('Обновление не найдено — проверьте ещё раз');
    if (busy) throw new Error('Обновление уже скачивается');
    busy = true;
    const send = (ch, v) => { try { getWin()?.webContents.send(ch, v); } catch {} };
    try {
      const { version, file, sig } = pending;
      // 1. подпись: какой файл, какая версия, какой SHA-256
      const sr = await net.fetch(sig.browser_download_url, { headers: { 'user-agent': 'Lastochka-Updater' } });
      if (!sr.ok) throw new Error('Не удалось скачать подпись');
      const s = JSON.parse(await sr.text());
      const msg = `lastochka|${s.version}|${s.file}|${s.sha256}`;
      const okSig = crypto.verify(null, Buffer.from(msg), PUBLIC_KEY, Buffer.from(String(s.sig || ''), 'base64'));
      if (!okSig) throw new Error('Подпись обновления неверна — установка отменена');
      if (s.file !== file.name || s.version !== version) throw new Error('Подпись относится к другому файлу — установка отменена');
      if (cmpVer(s.version, app.getVersion()) <= 0) throw new Error('Подписанная версия не новее текущей');
      // 2. сам файл: качаем, считаем SHA-256 по ходу
      const dir = path.join(app.getPath('temp'), 'lastochka-update');
      fs.mkdirSync(dir, { recursive: true });
      const target = path.join(dir, file.name);
      const r = await net.fetch(file.browser_download_url, { headers: { 'user-agent': 'Lastochka-Updater' } });
      if (!r.ok || !r.body) throw new Error('Не удалось скачать обновление (' + r.status + ')');
      const total = +r.headers.get('content-length') || file.size || 0;
      const hash = crypto.createHash('sha256'), out = fs.createWriteStream(target);
      let got = 0, lastPct = -1;
      const reader = r.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        const buf = Buffer.from(value);
        hash.update(buf); got += buf.length;
        if (!out.write(buf)) await new Promise(res => out.once('drain', res));
        const pct = total ? Math.floor(got * 100 / total) : 0;
        if (pct !== lastPct) { lastPct = pct; send('update:progress', pct); }
      }
      await new Promise((res, rej) => out.end(err => err ? rej(err) : res()));
      const sha = hash.digest('hex');
      if (sha !== s.sha256) { try { fs.unlinkSync(target); } catch {} throw new Error('Файл обновления повреждён или подменён — установка отменена'); }
      // 3. установка
      if (process.platform === 'win32' && !isPortable()) {
        // тихая установка поверх текущей; Windows попросит права администратора (установка для всех пользователей)
        spawn('cmd.exe', ['/c', 'start', '""', target, '/S', '--force-run'], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
        setTimeout(quit, 800);
        return { done: true, mode: 'installer' };
      }
      if (process.platform === 'win32') {
        const dest = path.join(path.dirname(process.env.PORTABLE_EXECUTABLE_FILE), file.name);
        try { fs.copyFileSync(target, dest); } catch { }
        shell.showItemInFolder(fs.existsSync(dest) ? dest : target);
        return { done: true, mode: 'portable', path: fs.existsSync(dest) ? dest : target };
      }
      await shell.openPath(target);  // macOS: откроется образ — перетащите Ласточку в «Программы»
      return { done: true, mode: 'dmg' };
    } finally { busy = false; }
  });
};
