// Защита от вредоносных файлов из чата: программы и скрипты не открываются сами,
// а все сохранённые файлы помечаются как «из интернета» — тогда Windows SmartScreen,
// антивирус и защищённый режим Office проверяют их так же, как скачанные браузером.
import 'dart:io';

import 'diag.dart';

const _dangerousWin = {
  'exe', 'msi', 'msp', 'bat', 'cmd', 'com', 'scr', 'pif', 'cpl', 'msc', 'vb', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'ws',
  'ps1', 'ps1xml', 'psm1', 'psd1', 'hta', 'lnk', 'url', 'reg', 'inf', 'scf', 'jar', 'appx', 'appxbundle', 'msix', 'msixbundle',
  'dll', 'sys', 'ocx', 'gadget', 'application', 'appref-ms', 'iso', 'img', 'vhd', 'vhdx', 'xll', 'settingcontent-ms', 'library-ms',
};
const _dangerousMac = {'app', 'command', 'tool', 'pkg', 'mpkg', 'dmg', 'sh', 'zsh', 'workflow', 'scpt', 'terminal', 'jar', 'webloc'};
const _dangerousAndroid = {'apk', 'apks', 'xapk', 'aab'};

String fileExt(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase().trim();
}

/// Программа, скрипт, ярлык или образ диска — открывать одним нажатием опасно.
bool isDangerousFile(String name) {
  final e = fileExt(name);
  return _dangerousWin.contains(e) || _dangerousMac.contains(e) || _dangerousAndroid.contains(e);
}

/// Пометить файл «загружен из интернета».
Future<void> markFromInternet(String path) async {
  try {
    if (Platform.isWindows) {
      // альтернативный поток NTFS — так помечает файлы любой браузер (Mark of the Web)
      await File('$path:Zone.Identifier').writeAsString('[ZoneTransfer]\r\nZoneId=3\r\nHostUrl=about:internet\r\n', flush: true);
    } else if (Platform.isMacOS) {
      // карантин Gatekeeper; дополнительно включён LSFileQuarantineEnabled для всего приложения
      final hex = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toRadixString(16);
      await Process.run('/usr/bin/xattr', ['-w', 'com.apple.quarantine', '0081;$hex;Lastochka;', path]);
    }
  } catch (e) {
    Diag.err('Пометка файла «из интернета»', e);
  }
}

/// Показать файл в папке (Проводник / Finder).
Future<void> revealInFolder(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [File(path).parent.path]);
    }
  } catch (_) {}
}
