// Защита от вредоносных файлов из чата: программы и скрипты не открываются сами,
// а все сохранённые файлы помечаются как «из интернета» — тогда Windows SmartScreen,
// антивирус и защищённый режим Office проверяют их так же, как скачанные браузером.
import 'dart:io';

import 'diag.dart';

const _dangerousWin = {
  'exe', 'msi', 'msp', 'bat', 'cmd', 'com', 'scr', 'pif', 'cpl', 'msc', 'vb', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh', 'ws',
  'ps1', 'ps1xml', 'psm1', 'psd1', 'hta', 'lnk', 'url', 'reg', 'inf', 'scf', 'jar', 'appx', 'appxbundle', 'msix', 'msixbundle',
  'dll', 'sys', 'ocx', 'gadget', 'application', 'appref-ms', 'iso', 'img', 'vhd', 'vhdx', 'xll', 'settingcontent-ms', 'library-ms',
  // справка, установщики и сценарии, которые тоже запускают код
  'chm', 'hlp', 'msu', 'appinstaller', 'msh', 'msh1', 'msh2', 'mshxml', 'msh1xml', 'msh2xml', 'sct', 'wsc', 'ps2', 'ps2xml',
  'psc1', 'psc2', 'diagcab', 'search-ms', 'searchconnector-ms', 'xbap', 'jnlp', 'one', 'onepkg', 'wsb', 'vsix', 'mde', 'ade',
  'adp', 'mda', 'mdb', 'accde', 'cer', 'crt', 'der', 'py', 'pyw', 'pyz', 'pyc', 'rdp', 'website', 'mht', 'mhtml', 'xhtml',
  'html', 'htm', 'svg', 'cab', 'theme', 'themepack', 'deskthemepack', 'ppkg', 'contact', 'vcf',
};
const _dangerousMac = {
  'app', 'command', 'tool', 'pkg', 'mpkg', 'dmg', 'sh', 'zsh', 'workflow', 'scpt', 'scptd', 'terminal', 'jar', 'webloc',
  'fileloc', 'inetloc', 'action', 'definition', 'py', 'pl', 'rb', 'osax', 'prefpane', 'kext', 'bash', 'csh', 'ksh',
};
const _dangerousLinux = {'desktop', 'appimage', 'run', 'deb', 'rpm', 'sh'};
const _dangerousAndroid = {'apk', 'apks', 'xapk', 'aab'};

/// Расширение файла. Точки и пробелы в конце не считаются: Windows их отбрасывает,
/// и «счёт.exe.» превратился бы в «счёт.exe», проскочив проверку.
String fileExt(String name) {
  final n = name.replaceAll(RegExp(r'[.\s]+$'), '');
  final i = n.lastIndexOf('.');
  return i < 0 ? '' : n.substring(i + 1).toLowerCase().trim();
}

/// Имя файла без хвостовых точек и пробелов и без зарезервированных имён Windows (CON, NUL, COM1…).
String safeFileName(String name) {
  var n = name.replaceAll(RegExp(r'[.\s]+$'), '');
  final stem = n.split('.').first.toUpperCase();
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$').hasMatch(stem)) n = '_$n';
  return n;
}

/// Программа, скрипт, ярлык или образ диска — открывать одним нажатием опасно.
bool isDangerousFile(String name) {
  final e = fileExt(name);
  return _dangerousWin.contains(e) || _dangerousMac.contains(e) || _dangerousAndroid.contains(e) || _dangerousLinux.contains(e);
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
