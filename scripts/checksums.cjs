// Записывает SHA-256 готовых установщиков в release/SHA256SUMS.txt —
// по ним получатель проверяет, что файл не подменили по дороге.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const dir = path.join(__dirname, '..', 'release');
const files = fs.existsSync(dir) ? fs.readdirSync(dir).filter(f => /\.(dmg|exe)$/i.test(f)) : [];
const lines = files.map(f => crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, f))).digest('hex') + '  ' + f);
fs.writeFileSync(path.join(dir, 'SHA256SUMS.txt'), lines.join('\n') + '\n');
console.log('\nSHA-256:\n' + lines.join('\n'));
