// Подписывает файлы релиза новой Ласточки (Flutter) тем же ключом Ed25519, что и прежнюю версию.
// Запуск: UPDATE_SIGNING_KEY=... node scripts/sign-files.cjs <папка> <версия>
// Для каждого файла рядом появляется <файл>.sig — JSON {version, file, sha256, sig}.
const crypto = require('node:crypto'), fs = require('node:fs'), path = require('node:path');
const key = process.env.UPDATE_SIGNING_KEY;
const [dir, version] = process.argv.slice(2);
if (!key) { console.error('Нет UPDATE_SIGNING_KEY — подпись невозможна'); process.exit(1); }
if (!dir || !version) { console.error('Использование: sign-files.cjs <папка> <версия>'); process.exit(1); }
const files = fs.readdirSync(dir).filter(f => /\.(dmg|exe|apk|zip|ipa)$/i.test(f));
if (!files.length) { console.error('Нет файлов для подписи'); process.exit(1); }
for (const f of files) {
  const sha256 = crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, f))).digest('hex');
  const msg = `lastochka|${version}|${f}|${sha256}`;
  const sig = crypto.sign(null, Buffer.from(msg), key).toString('base64');
  fs.writeFileSync(path.join(dir, f + '.sig'), JSON.stringify({ version, file: f, sha256, sig }, null, 2));
  console.log('подписан', f, sha256);
}
