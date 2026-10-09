// Шаг после упаковки (afterPack): включает Electron Fuses в готовом .app/.exe.
// Выполняется ДО подписи, поэтому подпись остаётся корректной.
const path = require('node:path');
const { flipFuses, FuseVersion, FuseV1Options } = require('@electron/fuses');

module.exports = async function afterPack(ctx) {
  const plat = ctx.electronPlatformName;
  const name = ctx.packager.appInfo.productFilename;
  const target = plat === 'darwin' ? path.join(ctx.appOutDir, name + '.app')
    : plat === 'win32' ? path.join(ctx.appOutDir, name + '.exe')
    : path.join(ctx.appOutDir, ctx.packager.executableName);
  const fuses = {
    version: FuseVersion.V1,
    resetAdHocDarwinSignature: plat === 'darwin',
    [FuseV1Options.RunAsNode]: false,                          // нельзя запустить как Node.js
    [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false, // NODE_OPTIONS игнорируется
    [FuseV1Options.EnableNodeCliInspectArguments]: false,      // нельзя подключить отладчик
    [FuseV1Options.EnableCookieEncryption]: true,
    [FuseV1Options.OnlyLoadAppFromAsar]: true,                 // код только из app.asar
    [FuseV1Options.GrantFileProtocolExtraPrivileges]: false,
  };
  // Проверка целостности app.asar: на macOS electron-builder записывает хэш в Info.plist.
  if (plat === 'darwin') fuses[FuseV1Options.EnableEmbeddedAsarIntegrityValidation] = true;
  await flipFuses(target, fuses);
  console.log('  • Electron Fuses включены:', path.basename(target));
};
