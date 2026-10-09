// Проверка, отвечает ли сервер звонков (coturn) с этого компьютера.
// Запуск:  node scripts/turn-check.cjs   (укажите адреса: node scripts/turn-check.cjs turn.example.ru 10.0.0.5)
const dgram = require('dgram'), net = require('net'), crypto = require('crypto'), dns = require('dns').promises, os = require('os');

const hosts = process.argv.slice(2);
if (!hosts.length) { console.log('Укажите адреса сервера звонков: node scripts/turn-check.cjs сервер [внутренний-IP]'); process.exit(1); }
const PORT = 3478;

function bindingRequest(){
  const b = Buffer.alloc(20);
  b.writeUInt16BE(0x0001, 0); b.writeUInt16BE(0, 2); b.writeUInt32BE(0x2112A442, 4);
  crypto.randomBytes(12).copy(b, 8);
  return b;
}
function mapped(buf){
  let i = 20;
  while (i + 4 <= buf.length) {
    const t = buf.readUInt16BE(i), l = buf.readUInt16BE(i + 2), v = buf.subarray(i + 4, i + 4 + l);
    if ((t === 0x0020 || t === 0x0001) && v[1] === 1) {
      const x = t === 0x0020;
      const port = v.readUInt16BE(2) ^ (x ? 0x2112 : 0);
      const ip = [...v.subarray(4, 8)].map((o, k) => o ^ (x ? [0x21, 0x12, 0xA4, 0x42][k] : 0)).join('.');
      return `${ip}:${port}`;
    }
    i += 4 + l + ((4 - l % 4) % 4);
  }
  return '?';
}
function udp(ip){
  return new Promise(res => {
    const s = dgram.createSocket('udp4'), req = bindingRequest();
    const t = setTimeout(() => { s.close(); res('❌ нет ответа за 3 с'); }, 3000);
    s.on('message', m => { clearTimeout(t); s.close(); res('✅ отвечает, видит вас как ' + mapped(m)); });
    s.on('error', e => { clearTimeout(t); s.close(); res('❌ ошибка: ' + e.message); });
    s.send(req, PORT, ip);
  });
}
function tcp(ip){
  return new Promise(res => {
    const s = net.connect(PORT, ip), req = bindingRequest(); let data = Buffer.alloc(0);
    const t = setTimeout(() => { s.destroy(); res(data.length ? '⚠️ ответ неполный' : '❌ подключились, но ответа нет'); }, 3000);
    s.on('connect', () => s.write(req));
    s.on('data', d => { data = Buffer.concat([data, d]); if (data.length >= 20) { clearTimeout(t); s.destroy(); res('✅ отвечает, видит вас как ' + mapped(data)); } });
    s.on('error', e => { clearTimeout(t); res('❌ ошибка: ' + e.message); });
  });
}
(async () => {
  console.log('Сетевые адаптеры этого компьютера:');
  for (const [n, list] of Object.entries(os.networkInterfaces())) for (const a of list) if (a.family === 'IPv4' && !a.internal) console.log(`  ${n}: ${a.address}`);
  for (const h of hosts) {
    let ip = h;
    try { if (!net.isIP(h)) ip = (await dns.lookup(h, {family:4})).address; } catch (e) { console.log(`\n${h}: не удалось узнать IP (${e.message})`); continue; }
    console.log(`\n${h} (${ip}), порт ${PORT}:`);
    console.log('  UDP: ' + await udp(ip));
    console.log('  TCP: ' + await tcp(ip));
  }
  console.log('\nСкопируйте всё, что выше, и пришлите.');
})();
