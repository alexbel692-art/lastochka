// Единственный мост между системой и окном. Окну доступны только:
// сигнал блокировки экрана и защищённое хранилище сессии/ключа.
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('desktop', {
  versions: { electron: process.versions.electron, chrome: process.versions.chrome },
  onSystemLock: cb => { ipcRenderer.on('system-lock', () => cb()); },
  show: () => ipcRenderer.send('win:show'),
  protect: on => ipcRenderer.send('win:protect', !!on),
  titleBar: (color, symbol) => ipcRenderer.send('win:titlebar', color, symbol),
  notify: n => ipcRenderer.send('notify:show', n),
  clearNotify: tag => ipcRenderer.send('notify:clear', tag),
  turnStats: reset => ipcRenderer.invoke('turn:stats', !!reset),
  turnProxy: (host, port, user, pass) => ipcRenderer.invoke('turn:proxy', host, port, user, pass),
  update: {
    check: () => ipcRenderer.invoke('update:check'),
    install: () => ipcRenderer.invoke('update:install'),
    onProgress: cb => { ipcRenderer.on('update:progress', (_e, p) => cb(p)); },
  },
  probe: targets => ipcRenderer.invoke('net:probe', targets),
  onNotifyClick: cb => { ipcRenderer.on('notify:click', (_e, tag) => cb(tag)); },
  secure: {
    info: () => ipcRenderer.invoke('secure:info'),
    getSession: () => ipcRenderer.invoke('secure:getSession'),
    setSession: s => ipcRenderer.invoke('secure:setSession', s),
    clear: () => ipcRenderer.invoke('secure:clear'),
    storageKey: (userId, deviceId) => ipcRenderer.invoke('secure:storageKey', userId, deviceId),
  },
});
