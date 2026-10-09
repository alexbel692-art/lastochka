// Подписывает собранные файлы ключом разработчика (Ed25519) для проверки обновлений.
// Ключ берётся из переменной окружения UPDATE_SIGNING_KEY (секрет GitHub Actions).
// Для каждого .dmg / .exe в release/ рядом появляется <файл>.sig — JSON с версией, SHA-256 и подписью.
const crypto = require('node:crypto'), fs = require('node:fs'), path = require('node:path');
const key = process.env.UPDATE_SIGNING_KEY;
if (!key) { console.error('Нет UPDATE_SIGNING_KEY — подпись невозможна'); process.exit(1); }
const version = require('../package.json').version;
const dir = path.join(__dirname, '..', 'release');
const files = fs.readdirSync(dir).filter(f => /\.(dmg|exe)$/i.test(f) && !/blockmap/i.test(f) && !/uninstall/i.test(f));
if (!files.length) { console.error('В release/ нет файлов для подписи'); process.exit(1); }
for (const f of files) {
  const sha256 = crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, f))).digest('hex');
  const msg = `lastochka|${version}|${f}|${sha256}`;
  const sig = crypto.sign(null, Buffer.from(msg), key).toString('base64');
  fs.writeFileSync(path.join(dir, f + '.sig'), JSON.stringify({ version, file: f, sha256, sig }, null, 2));
  console.log('подписан', f, sha256);
}
