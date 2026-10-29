// Стикеры и эмодзи — те же наборы и форматы, что в настольной Ласточке:
// встроенные «Ласточка», «Котик», «Эмоции», свои стикеры (im.ponies.user_emotes)
// и наборы чата (im.ponies.room_emotes). Встроенный стикер загружается на сервер
// один раз, дальше переиспользуется ссылка mxc.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../system/trust.dart';
import '../main.dart';
import 'autodelete.dart';
import '../system/diag.dart';
import '../widgets/mxc_image.dart';
import 'gif_panel.dart';
import 'save_media.dart';
import 'sticker_packs.dart';

class StickerImg {
  final String key, body;
  final String? asset; // встроенный стикер
  final Uri? url; // mxc://
  final Map<String, Object?> info;
  final String? packId; // свой набор (для ссылки «добавить набор» у получателя)
  StickerImg({required this.key, required this.body, this.asset, this.url, this.info = const {}, this.packId});
}

class StickerPack {
  final String name;
  final List<StickerImg> items;
  final bool own;
  /// Свой набор: ownPackId («Мои стикеры») или id набора; null — встроенный или набор чата.
  final String? id;
  StickerPack(this.name, this.items, {this.own = false, this.id});
}

// Набор «Смайлы»: объёмные эмодзи Noto 3D (Google, свободная лицензия — assets/stickers/NOTO-LICENSE.txt)
const _smiles = [
  ('z_smeh', 'Ха-ха'), ('z_katayus', 'Катаюсь'), ('z_vlyublen', 'Влюблён'), ('z_nezhnost', 'Нежность'), ('z_potseluy', 'Целую'), ('z_kruto', 'Круто'),
  ('z_dumayu', 'Думаю'), ('z_uzhas', 'Ужас!'), ('z_rydayu', 'Рыдаю'), ('z_besyus', 'Бешусь'), ('z_prazdnik', 'Праздник'), ('z_vostorg', 'Восторг'),
  ('z_splyu', 'Сплю'), ('z_mozg', 'Взрыв мозга'), ('z_nuuu', 'Ну-ну'), ('z_hitro', 'Хитро'), ('z_like', 'Класс'), ('z_okey', 'Окей'),
  ('z_spasibo', 'Спасибо'), ('z_sila', 'Сила'), ('z_ogon', 'Огонь'), ('z_serdce', 'Сердце'), ('z_hlopushka', 'Поздравляю'), ('z_sto', 'Сто процентов'),
  ('z_aplodismenty', 'Браво'), ('z_deal', 'Договорились'), ('z_nu_pozhaluysta', 'Ну пожалуйста'), ('z_obnimashki', 'Обнимашки'), ('z_neudobno', 'Неловко'), ('z_est', 'Есть!'),
  ('z_umer', 'Умер со смеху'), ('z_ne_vizhu', 'Не вижу'), ('z_oy', 'Ой'), ('z_kotik', 'Котик'), ('z_raketa', 'Погнали'), ('z_podarok', 'Подарок'),
];

const _builtin = [
  ('Смайлы', _smiles),
  ('Ласточка', [('privet', 'Привет!'), ('haha', 'Ха-ха!'), ('lyublyu', 'Люблю'), ('super', 'Супер!'), ('ok', 'Ок'), ('ura', 'Ура!'), ('ogo', 'Ого!'), ('spasibo', 'Спасибо!'), ('kofe', 'Кофе?'), ('grushchu', 'Грущу'), ('zlyus', 'Злюсь'), ('splyu', 'Сплю')]),
  ('Котик', [('c_privet', 'Привет!'), ('c_mur', 'Мур'), ('c_ok', 'Окей'), ('c_utro', 'Доброе утро'), ('c_noch', 'Спокойной ночи'), ('c_obnim', 'Обнимаю'), ('c_rabota', 'Работаю'), ('c_zhdu', 'Жду…'), ('c_ura', 'Ура!'), ('c_ups', 'Упс'), ('c_chto', 'Что?!'), ('c_lyublyu', 'Люблю тебя'), ('c_zlyus', 'Сержусь'), ('c_spasibo', 'Спасибо'), ('c_poka', 'Пока!'), ('c_kushat', 'Ням')]),
  ('Эмоции', [('e_klass', 'Класс!'), ('e_ogon', 'Огонь!'), ('e_lyubov', 'Люблю'), ('e_oru', 'Ору'), ('e_plachu', 'Плачу'), ('e_hm', 'Хм…'), ('e_pozdr', 'Поздравляю!'), ('e_bravo', 'Браво!'), ('e_pozh', 'Пожалуйста'), ('e_chetko', 'Чётко'), ('e_shok', 'Шок!'), ('e_100', 'Точно'), ('e_dogovor', 'Договорились'), ('e_ustal', 'Устал'), ('e_facepalm', 'Ну как так'), ('e_obnim', 'Обнимаю')]),
  ('Мемы', [('m_lapki', 'У меня лапки'), ('m_podozr', 'Подозрительно…'), ('m_ya_vse', 'Я всё'), ('m_kofe', 'Мой кофе!'), ('m_ponedelnik', 'Понедельник…'), ('m_hochu', 'Хочу!'), ('m_ponyatiya', 'Без понятия'), ('m_shpion', 'Я только посмотреть'), ('m_pyatnitsa', 'Пятница!'), ('m_dedlain', 'Дедлайн!'), ('m_obida', 'Обиделась'), ('m_slezhu', 'Слежу'), ('m_spat', 'Спать пора'), ('m_obnimashki', 'Обнимашки')]),
];

List<StickerImg> _fromImages(Map? images, [String? packId]) {
  final out = <StickerImg>[];
  if (images == null) return out;
  for (final MapEntry(:key, :value) in images.entries) {
    if (value is! Map) continue;
    final usage = value['usage'];
    if (usage is List && usage.isNotEmpty && !usage.contains('sticker')) continue;
    final url = Uri.tryParse('${value['url'] ?? ''}');
    if (url == null || url.scheme != 'mxc') continue;
    out.add(StickerImg(
      key: '$key',
      body: '${value['body'] ?? key}',
      url: url,
      info: value['info'] is Map ? Map<String, Object?>.from(value['info'] as Map) : const {},
      packId: packId,
    ));
  }
  return out;
}

List<StickerPack> stickerPacks(Room room) {
  final packs = [
    for (final (name, list) in _builtin)
      StickerPack(name, [
        for (final (k, body) in list)
          k.startsWith('z_')
              ? StickerImg(key: 'lastochka_$k', body: body, asset: 'assets/stickers/$k.webp', info: const {'w': 320, 'h': 320, 'mimetype': 'image/webp'})
              : StickerImg(key: 'lastochka_$k', body: body, asset: 'assets/stickers/$k.png', info: const {'w': 512, 'h': 512, 'mimetype': 'image/png'}),
      ]),
  ];
  final own = client.accountData['im.ponies.user_emotes']?.content;
  packs.add(StickerPack('Мои стикеры', _fromImages(own?['images'] as Map?, ownPackId), own: true, id: ownPackId));
  for (final p in userPacks()) {
    packs.add(StickerPack(p.name, [
      for (final it in p.items) StickerImg(key: it.key, body: it.body, url: it.url, info: it.info, packId: p.id),
    ], own: true, id: p.id));
  }
  for (final ev in room.states['im.ponies.room_emotes']?.values ?? const <StrippedStateEvent>[]) {
    final items = _fromImages(ev.content['images'] as Map?);
    if (items.isEmpty) continue;
    final pack = ev.content['pack'];
    packs.add(StickerPack(pack is Map && pack['display_name'] is String ? pack['display_name'] as String : 'Стикеры чата', items));
  }
  return packs;
}

Future<Uri> _builtinMxc(StickerImg s) async {
  final prefs = await SharedPreferences.getInstance();
  final key = 'lastochka.stk.${client.userID}';
  final cache = Map<String, dynamic>.from(jsonDecode(prefs.getString(key) ?? '{}') as Map);
  // ключ кэша тот же, что у настольной версии (./stickers/имя.png)
  final local = './stickers/${s.asset!.split('/').last}';
  if (cache[local] is String) return Uri.parse(cache[local] as String);
  final bytes = (await rootBundle.load(s.asset!)).buffer.asUint8List();
  final uri = await client.uploadContent(bytes, filename: s.asset!.split('/').last, contentType: '${s.info['mimetype'] ?? 'image/png'}');
  cache[local] = uri.toString();
  await prefs.setString(key, jsonEncode(cache));
  return uri;
}

Future<void> sendSticker(Room room, StickerImg s, {Event? inReplyTo}) async {
  final url = s.url ?? await _builtinMxc(s);
  // свой набор — со ссылкой на него: получатель сможет добавить набор целиком
  final ref = s.packId == null ? null : await packRefFor(s.packId!);
  ensureCanSend(room);
  await room.sendEvent({'body': s.body, 'url': url.toString(), 'info': {...s.info}, if (ref != null) packRefKey: ref, ...ttlExtra(room)},
      type: EventTypes.Sticker, inReplyTo: inReplyTo);
}

Map<String, dynamic> _ownPack() => Map<String, dynamic>.from(client.accountData['im.ponies.user_emotes']?.content ?? {});

Future<void> _saveOwn(Map<String, dynamic> prev, Map<String, dynamic> images) => client.setAccountData(client.userID!, 'im.ponies.user_emotes', {
      ...prev,
      'pack': {'display_name': 'Мои стикеры', ...(prev['pack'] as Map? ?? {})},
      'images': images,
    });

String _freeKey(Map<String, dynamic> images, String name) {
  var base = name.replaceAll(RegExp(r'\.[a-z0-9]+$', caseSensitive: false), '').replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '_');
  if (base.isEmpty) base = 'sticker';
  if (base.length > 32) base = base.substring(0, 32);
  var sc = base;
  for (var n = 2; images.containsKey(sc); n++) {
    sc = '${base}_$n';
  }
  return sc;
}

/// Поделиться набором в группе: он появится у всех участников во вкладке стикеров этого чата.
Future<String> sharePackToRoom(Room room, String packId, String name) async {
  final images = packImages(packId);
  if (images.isEmpty) return 'В наборе пока пусто';
  if (!room.canChangeStateEvent('im.ponies.room_emotes')) return 'Нужны права администратора группы';
  final me = client.userID!;
  await client.setRoomStateWithKey(room.id, 'im.ponies.room_emotes', 'lastochka_${me.localpart}_$packId', {
    'pack': {'display_name': packId == ownPackId ? 'Стикеры ${(await client.fetchOwnProfile()).displayName ?? me.localpart}' : name},
    'images': images,
  });
  return 'Набор доступен всем в этом чате';
}

/// Сохранить стикер или картинку из чата в «Мои стикеры».
Future<String> addToOwnPack(Event e) async {
  final url = e.content.tryGet<String>('url');
  if (url == null) return 'Это изображение зашифровано — сохранить его как стикер нельзя';
  final prev = Map<String, dynamic>.from(client.accountData['im.ponies.user_emotes']?.content ?? {});
  final images = Map<String, dynamic>.from(prev['images'] as Map? ?? {});
  if (images.values.any((x) => x is Map && x['url'] == url)) return 'Этот стикер уже есть';
  var base = e.body.replaceAll(RegExp(r'\.[a-z0-9]+$', caseSensitive: false), '').replaceAll(RegExp(r'[^\p{L}\p{N}_-]+', unicode: true), '_');
  if (base.isEmpty) base = 'sticker';
  if (base.length > 32) base = base.substring(0, 32);
  var sc = base;
  for (var n = 2; images.containsKey(sc); n++) {
    sc = '${base}_$n';
  }
  images[sc] = {'url': url, 'body': e.body, 'info': e.content['info'] ?? {}, 'usage': ['sticker']};
  await client.setAccountData(client.userID!, 'im.ponies.user_emotes', {
    ...prev,
    'pack': {'display_name': 'Мои стикеры', ...(prev['pack'] as Map? ?? {})},
    'images': images,
  });
  return 'Стикер добавлен';
}

const emojiCats = [
  ('😀', 'Смайлы', '😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😙 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🤫 🤔 🤐 🤨 😐 😑 😶 😏 😒 🙄 😬 😮‍💨 🤥 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🥵 🥶 🥴 😵 🤯 🤠 🥳 😎 🤓 🧐 😕 😟 🙁 😮 😯 😲 😳 🥺 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 😡 😠 🤬 😈 👿 💀 💩 🤡 👻 👽 🤖 😺 😸 😹 😻 😼 😽 🙀 😿 😾'),
  ('👍', 'Жесты и люди', '👋 🤚 🖐 ✋ 🖖 👌 🤌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 👐 🤲 🤝 🙏 ✍️ 💅 💪 👀 👁 👅 👄 🧠 🫶 👶 🧒 👦 👧 🧑 👱 👨 🧔 👩 🧓 👴 👵 🙍 🙎 🙅 🙆 💁 🙋 🙇 🤦 🤷 👮 🕵️ 💂 👷 🤴 👸 🧑‍💻 🧑‍🔧 🧑‍🍳 🧑‍🎓 🧑‍⚕️ 🧑‍🏫 🏃 🚶 💃 🕺 👯 🧘 🛌 👫 👪'),
  ('❤️', 'Сердца и символы', '❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💯 💢 💥 💫 💦 💨 💬 💭 💤 ✅ ☑️ ✔️ ❌ ❎ ➕ ➖ ❗ ❓ ‼️ ⁉️ ⚠️ 🚫 ⛔ ♻️ 🔥 ✨ ⭐ 🌟 ⚡ 🎵 🎶 🔔 🔕 📌 📍 🔒 🔓 🔑 🆗 🆕 🆒 🆘 ▶️ ⏸ ⏹ 🔴 🟠 🟡 🟢 🔵 🟣 ⚫ ⚪'),
  ('🐶', 'Животные и природа', '🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐔 🐧 🐦 🐤 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝 🐛 🦋 🐌 🐞 🐜 🐢 🐍 🦎 🐙 🦑 🦀 🐠 🐟 🐬 🐳 🐋 🦈 🐊 🐅 🐆 🦓 🐘 🦒 🦘 🐪 🐄 🐎 🐖 🐑 🐐 🦌 🐕 🐈 🐓 🦃 🕊 🐇 🦔 🐾 🌵 🎄 🌲 🌳 🌴 🌱 🌿 ☘️ 🍀 🍁 🍂 🍃 🌷 🌹 🥀 🌺 🌸 🌼 🌻 🌞 🌝 🌚 🌙 🌎 🪐 ☀️ ⛅ ☁️ 🌧 ⛈ ❄️ ☃️ ⛄ 🌈 🌊'),
  ('🍕', 'Еда и напитки', '🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🥦 🥬 🥒 🌶 🌽 🥕 🧄 🧅 🥔 🥐 🥯 🍞 🥖 🧀 🥚 🍳 🧈 🥞 🧇 🥓 🥩 🍗 🍖 🌭 🍔 🍟 🍕 🥪 🌮 🌯 🥗 🍝 🍜 🍲 🍛 🍣 🍱 🥟 🍤 🍙 🍚 🍰 🎂 🧁 🍮 🍭 🍬 🍫 🍿 🍩 🍪 🍯 ☕ 🍵 🧃 🥤 🧋 🍺 🍻 🥂 🍷 🥃 🍸 🍹 🍾 🧊'),
  ('⚽', 'Занятия', '⚽ 🏀 🏈 ⚾ 🎾 🏐 🏉 🎱 🏓 🏸 🏒 🥊 🥋 ⛳ ⛸ 🎣 🎿 🛷 🏂 🏋️ 🤸 🤺 🏊 🚴 🧗 🏆 🥇 🥈 🥉 🏅 🎖 🎫 🎪 🎭 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🎷 🎺 🎸 🎻 🎲 ♟ 🎯 🎳 🎮 🕹 🧩 🎉 🎊 🎈 🎁 🎀'),
  ('🚗', 'Транспорт и места', '🚗 🚕 🚙 🚌 🚎 🏎 🚓 🚑 🚒 🚐 🚚 🚛 🚜 🏍 🛵 🚲 🛴 🚨 🚍 ✈️ 🛫 🛬 🚀 🛸 🚁 ⛵ 🚤 🛳 🚢 ⚓ 🚂 🚆 🚇 🚊 🗺 🗽 🗼 🏰 🏯 🏟 🎡 🎢 🎠 ⛲ 🏖 🏝 🏜 🌋 ⛰ 🏔 🏕 🏠 🏡 🏢 🏬 🏥 🏦 🏨 🏪 🏫 ⛪ 🕌 🌃 🌆 🌇 🌉 🌌 🎆 🎇'),
  ('💡', 'Предметы', '⌚ 📱 💻 ⌨️ 🖥 🖨 🖱 💾 💿 📷 📸 📹 🎥 📞 ☎️ 📺 📻 🎙 ⏰ ⏳ ⌛ 📡 🔋 🔌 💡 🔦 🕯 🧯 💸 💵 💳 💎 ⚖️ 🧰 🔧 🔨 🛠 ⛏ 🔩 ⚙️ 🧱 🧲 💣 🔪 🛡 🔮 🔭 🔬 💊 💉 🧬 🦠 🧪 🌡 🧹 🧺 🧻 🧼 🗝 🚪 🛋 🛏 🧸 🖼 🛍 🛒 ✉️ 📩 📦 📫 📜 📄 📑 📊 📈 📉 🗓 📆 📋 📁 📂 📰 📓 📒 📚 📖 🔖 🔗 📎 📐 📏 ✂️ 🖊 🖌 📝 ✏️ 🔍 🔎'),
  ('🏁', 'Флаги', '🇷🇺 🇧🇾 🇰🇿 🇺🇦 🇦🇲 🇦🇿 🇬🇪 🇺🇿 🇰🇬 🇹🇯 🇹🇲 🇲🇩 🇨🇳 🇮🇳 🇹🇷 🇦🇪 🇮🇱 🇯🇵 🇰🇷 🇹🇭 🇻🇳 🇮🇩 🇺🇸 🇨🇦 🇲🇽 🇧🇷 🇦🇷 🇬🇧 🇩🇪 🇫🇷 🇮🇹 🇪🇸 🇵🇹 🇳🇱 🇧🇪 🇨🇭 🇦🇹 🇵🇱 🇨🇿 🇸🇪 🇳🇴 🇫🇮 🇩🇰 🇬🇷 🇷🇸 🇪🇬 🇿🇦 🇦🇺 🏳️ 🏴 🏁 🚩'),
];

Future<List<String>> recentEmoji() async => (await SharedPreferences.getInstance()).getStringList('lastochka.recentEmoji') ?? [];
Future<void> pushRecentEmoji(String e) async {
  final p = await SharedPreferences.getInstance();
  final list = [e, ...(p.getStringList('lastochka.recentEmoji') ?? []).where((x) => x != e)].take(32).toList();
  await p.setStringList('lastochka.recentEmoji', list);
}

/// Панель вместо клавиатуры: вкладки «Эмодзи» и «Стикеры» — как в Telegram.
class EmojiStickerPanel extends StatefulWidget {
  final Room room;
  final void Function(String emoji) onEmoji;
  final void Function(StickerImg s) onSticker;
  /// GIF: сохранённая (SavedGif) или найденная (GifResult).
  final void Function(Object gif)? onGif;
  final double height;
  final int initialTab; // 0 — эмодзи, 1 — стикеры, 2 — GIF
  const EmojiStickerPanel({super.key, required this.room, required this.onEmoji, required this.onSticker, this.onGif, this.height = 300, this.initialTab = 0});
  @override
  State<EmojiStickerPanel> createState() => _EmojiStickerPanelState();
}

class _EmojiStickerPanelState extends State<EmojiStickerPanel> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: widget.onGif == null ? 2 : 3, vsync: this, initialIndex: widget.initialTab.clamp(0, widget.onGif == null ? 1 : 2));
  List<String> _recent = [];

  @override
  void initState() {
    super.initState();
    recentEmoji().then((r) => mounted ? setState(() => _recent = r) : null);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Widget _emojiTab() {
    final cats = [if (_recent.isNotEmpty) ('🕘', 'Недавние', _recent.join(' ')), ...emojiCats];
    return CustomScrollView(slivers: [
      for (final (_, title, list) in cats) ...[
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), child: Text(title, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)))),
        SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 44),
          delegate: SliverChildListDelegate([
            for (final e in list.split(' ').where((x) => x.isNotEmpty))
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  widget.onEmoji(e);
                  pushRecentEmoji(e);
                },
                child: Center(child: Text(e, style: const TextStyle(fontSize: 26))),
              ),
          ]),
        ),
      ],
    ]);
  }

  bool _busy = false;

  Future<void> _run(Future<String> f) async {
    if (_busy) return;
    setState(() => _busy = true);
    final msg = await f.catchError((Object e) {
      Diag.err('Стикеры', e);
      return 'Не получилось';
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (msg.isNotEmpty) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  bool get _desktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  Future<void> _remove(StickerPack pk, StickerImg s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Убрать стикер из «${pk.name}»?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Убрать')),
        ],
      ),
    );
    if (ok == true) {
      await removeFromPack(pk.id!, s.key);
      if (mounted) setState(() {});
    }
  }

  /// Картинки (и ZIP-архивы) с устройства → в набор.
  Future<String> _addTo(String packId, {bool archive = false}) async {
    final files = <(Uint8List, String)>[];
    if (_desktop || archive) {
      final picked = await FilePicker.pickFiles(
        dialogTitle: archive ? 'Архив с картинками (ZIP)' : 'Картинки или архив для набора',
        type: FileType.custom,
        allowedExtensions: archive ? const ['zip'] : const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'zip'],
      );
      for (final f in picked) {
        files.add((await f.readAsBytes(), f.name));
      }
    } else {
      final xs = await ImagePicker().pickMultiImage(requestFullMetadata: false, limit: 30);
      for (final x in xs) {
        files.add((await x.readAsBytes(), x.name));
      }
    }
    if (files.isEmpty) return '';
    final imgs = await compute(imagesFromFiles, files);
    if (imgs.isEmpty) return 'Картинок не найдено (подходят PNG, JPG, WebP, GIF и ZIP с ними)';
    final n = await addImagesToPack(packId, imgs);
    return n == 0 ? 'Не удалось добавить картинки' : 'Добавлено стикеров: $n';
  }

  Future<String?> _askName(String title, [String initial = '']) async {
    final c = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true, maxLength: 64, decoration: const InputDecoration(hintText: 'Название набора'), onSubmitted: (v) => Navigator.pop(d, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Готово')),
        ],
      ),
    );
    c.dispose();
    return r == null || r.trim().isEmpty ? null : r.trim();
  }

  Future<void> _newPack() async {
    final name = await _askName('Новый набор стикеров');
    if (name == null) return;
    await _run(() async {
      final id = await createPack(name);
      final msg = await _addTo(id);
      return msg.isEmpty ? 'Набор «$name» создан — добавьте в него картинки' : msg;
    }());
  }

  Future<String> _download(StickerPack pk) async {
    final items = [for (final s in pk.items) if (s.url != null) PackItem(s.key, s.body, s.url!, s.info)];
    if (items.isEmpty) return 'В наборе пока пусто';
    final zip = await packZip(pk.name, items);
    final where = await FilePicker.saveFile(dialogTitle: 'Сохранить набор', fileName: '${freeKey(const {}, pk.name)}.zip', bytes: zip, mimeType: 'application/zip');
    return where == null ? '' : 'Набор сохранён архивом';
  }

  Future<void> _packMenu(StickerPack pk, String action) async {
    final id = pk.id!;
    switch (action) {
      case 'add':
        await _run(_addTo(id));
      case 'zip':
        await _run(_addTo(id, archive: true));
      case 'rename':
        final name = await _askName('Переименовать набор', pk.name);
        if (name != null) await _run(renamePack(id, name).then((_) => ''));
      case 'download':
        await _run(_download(pk));
      case 'room':
        await _run(sharePackToRoom(widget.room, id, pk.name));
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text('Удалить набор «${pk.name}»?'),
            content: const Text('Набор пропадёт на всех ваших устройствах. У тех, кто его уже добавил, он останется.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
              FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Удалить')),
            ],
          ),
        );
        if (ok == true) await _run(deletePack(id).then((_) => 'Набор удалён'));
    }
    if (mounted) setState(() {});
  }

  Widget _stickerTab() {
    final packs = stickerPacks(widget.room);
    final hint = Theme.of(context).hintColor;
    final canRoom = !widget.room.isDirectChat && widget.room.canChangeStateEvent('im.ponies.room_emotes');
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: _busy ? null : _newPack, icon: const Icon(Icons.add_circle_outline, size: 18), label: const Text('Новый набор')),
          ),
        ),
      ),
      for (final pk in packs) ...[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 0, 0),
            child: Row(children: [
              Expanded(child: Text(pk.name, style: TextStyle(color: hint, fontSize: 13))),
              if (pk.own && pk.id != null)
                PopupMenuButton<String>(
                  tooltip: 'Набор',
                  icon: Icon(Icons.more_horiz, color: hint, size: 20),
                  onSelected: (a) => _packMenu(pk, a),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'add', child: Text('Добавить картинки')),
                    if (!_desktop) const PopupMenuItem(value: 'zip', child: Text('Добавить из архива (ZIP)')),
                    if (pk.id != ownPackId) const PopupMenuItem(value: 'rename', child: Text('Переименовать')),
                    if (pk.items.isNotEmpty) const PopupMenuItem(value: 'download', child: Text('Скачать набор (ZIP)')),
                    if (pk.items.isNotEmpty && canRoom) const PopupMenuItem(value: 'room', child: Text('Добавить в этот чат')),
                    if (pk.id != ownPackId) const PopupMenuItem(value: 'delete', child: Text('Удалить набор')),
                  ],
                ),
            ]),
          ),
        ),
        if (pk.items.isEmpty && pk.own)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text('«…» → «Добавить картинки» (можно архив ZIP). Или долгое нажатие на стикер в чате → «В мои стикеры». Нажатие на чужой стикер в чате — добавить его набор целиком.',
                  style: TextStyle(color: hint, fontSize: 12)),
            ),
          ),
        SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 84),
          delegate: SliverChildListDelegate([
            for (final s in pk.items)
              Tooltip(
                message: s.body,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => widget.onSticker(s),
                  onLongPress: pk.own && pk.id != null ? () => _remove(pk, s) : null,
                  onSecondaryTap: pk.own && pk.id != null ? () => _remove(pk, s) : null,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: s.asset != null ? Image.asset(s.asset!, fit: BoxFit.contain) : MxcImage(mxc: s.url!, size: 160, fit: BoxFit.contain),
                  ),
                ),
              ),
          ]),
        ),
      ],
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Column(children: [
        TabBar(controller: _tabs, tabs: [
          const Tab(text: 'Эмодзи', height: 38),
          const Tab(text: 'Стикеры', height: 38),
          if (widget.onGif != null) const Tab(text: 'GIF', height: 38),
        ]),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: TabBarView(controller: _tabs, children: [
            _emojiTab(),
            _stickerTab(),
            if (widget.onGif != null) GifTab(onSaved: widget.onGif!, onFound: widget.onGif!),
          ]),
        ),
      ]),
    );
  }
}

/// Нажатие на стикер в чате (как в Telegram): его набор — посмотреть и добавить целиком,
/// а также «В мои стикеры» и «Сохранить».
Future<void> showStickerPackSheet(BuildContext context, Event e) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _PackSheet(event: e),
    );

class _PackSheet extends StatefulWidget {
  final Event event;
  const _PackSheet({required this.event});
  @override
  State<_PackSheet> createState() => _PackSheetState();
}

class _PackSheetState extends State<_PackSheet> {
  late final Map<String, Object?>? _ref = widget.event.content.tryGetMap<String, Object?>(packRefKey);
  late final Future<(String, List<PackItem>)?>? _pack = _ref == null ? null : fetchPack(_ref);
  bool _busy = false;

  void _toast(String s) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(s)));

  Future<void> _do(Future<String> f) async {
    setState(() => _busy = true);
    try {
      _toast(await f);
    } catch (err) {
      Diag.err('Набор стикеров', err);
      _toast('Не получилось');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final manifest = _ref?['manifest'] as String?;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_pack == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('У этого стикера нет набора — его можно добавить к себе по одному', style: TextStyle(color: hint)),
            )
          else
            Flexible(
              child: FutureBuilder<(String, List<PackItem>)?>(
                future: _pack,
                builder: (context, s) {
                  if (s.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator());
                  final p = s.data;
                  if (p == null) {
                    return Padding(padding: const EdgeInsets.all(16), child: Text('Набор не загрузился — возможно, автор его удалил', style: TextStyle(color: hint)));
                  }
                  final (name, items) = p;
                  final added = manifest != null && packAdded(manifest);
                  return Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                    Text('${items.length} стикер${items.length % 10 == 1 && items.length % 100 != 11 ? '' : items.length % 10 >= 2 && items.length % 10 <= 4 && (items.length % 100 < 12 || items.length % 100 > 14) ? 'а' : 'ов'}',
                        style: TextStyle(color: hint, fontSize: 13)),
                    Flexible(
                      child: GridView.extent(
                        shrinkWrap: true,
                        maxCrossAxisExtent: 84,
                        padding: const EdgeInsets.all(8),
                        children: [for (final it in items) Padding(padding: const EdgeInsets.all(4), child: MxcImage(mxc: it.url, size: 160, fit: BoxFit.contain))],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                        onPressed: added || _busy || manifest == null
                            ? null
                            : () => _do(addPackFromManifest(manifest, name, items).then((_) {
                                  if (mounted) setState(() {});
                                  return 'Набор «$name» добавлен';
                                })),
                        icon: Icon(added ? Icons.check : Icons.add),
                        label: Text(added ? 'Набор уже добавлен' : 'Добавить набор'),
                      ),
                    ),
                  ]);
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              TextButton.icon(onPressed: _busy ? null : () => _do(addToOwnPack(widget.event)), icon: const Icon(Icons.emoji_emotions_outlined), label: const Text('В мои стикеры')),
              TextButton.icon(onPressed: () => saveMedia(context, widget.event), icon: const Icon(Icons.download_rounded), label: const Text('Сохранить')),
            ]),
          ),
        ]),
      ),
    );
  }
}
