// Стикеры и эмодзи — те же наборы и форматы, что в настольной Ласточке:
// встроенные «Ласточка», «Котик», «Эмоции», свои стикеры (im.ponies.user_emotes)
// и наборы чата (im.ponies.room_emotes). Встроенный стикер загружается на сервер
// один раз, дальше переиспользуется ссылка mxc.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import 'autodelete.dart';
import '../widgets/mxc_image.dart';

class StickerImg {
  final String key, body;
  final String? asset; // встроенный стикер
  final Uri? url; // mxc://
  final Map<String, Object?> info;
  StickerImg({required this.key, required this.body, this.asset, this.url, this.info = const {}});
}

class StickerPack {
  final String name;
  final List<StickerImg> items;
  final bool own;
  StickerPack(this.name, this.items, {this.own = false});
}

const _builtin = [
  ('Ласточка', [('privet', 'Привет!'), ('haha', 'Ха-ха!'), ('lyublyu', 'Люблю'), ('super', 'Супер!'), ('ok', 'Ок'), ('ura', 'Ура!'), ('ogo', 'Ого!'), ('spasibo', 'Спасибо!'), ('kofe', 'Кофе?'), ('grushchu', 'Грущу'), ('zlyus', 'Злюсь'), ('splyu', 'Сплю')]),
  ('Котик', [('c_privet', 'Привет!'), ('c_mur', 'Мур'), ('c_ok', 'Окей'), ('c_utro', 'Доброе утро'), ('c_noch', 'Спокойной ночи'), ('c_obnim', 'Обнимаю'), ('c_rabota', 'Работаю'), ('c_zhdu', 'Жду…'), ('c_ura', 'Ура!'), ('c_ups', 'Упс'), ('c_chto', 'Что?!'), ('c_lyublyu', 'Люблю тебя'), ('c_zlyus', 'Сержусь'), ('c_spasibo', 'Спасибо'), ('c_poka', 'Пока!'), ('c_kushat', 'Ням')]),
  ('Эмоции', [('e_klass', 'Класс!'), ('e_ogon', 'Огонь!'), ('e_lyubov', 'Люблю'), ('e_oru', 'Ору'), ('e_plachu', 'Плачу'), ('e_hm', 'Хм…'), ('e_pozdr', 'Поздравляю!'), ('e_bravo', 'Браво!'), ('e_pozh', 'Пожалуйста'), ('e_chetko', 'Чётко'), ('e_shok', 'Шок!'), ('e_100', 'Точно'), ('e_dogovor', 'Договорились'), ('e_ustal', 'Устал'), ('e_facepalm', 'Ну как так'), ('e_obnim', 'Обнимаю')]),
];

List<StickerImg> _fromImages(Map? images) {
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
    ));
  }
  return out;
}

List<StickerPack> stickerPacks(Room room) {
  final packs = [
    for (final (name, list) in _builtin)
      StickerPack(name, [for (final (k, body) in list) StickerImg(key: 'lastochka_$k', body: body, asset: 'assets/stickers/$k.png', info: const {'w': 512, 'h': 512, 'mimetype': 'image/png'})]),
  ];
  final own = client.accountData['im.ponies.user_emotes']?.content;
  packs.add(StickerPack('Мои стикеры', _fromImages(own?['images'] as Map?), own: true));
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
  final uri = await client.uploadContent(bytes, filename: s.asset!.split('/').last, contentType: 'image/png');
  cache[local] = uri.toString();
  await prefs.setString(key, jsonEncode(cache));
  return uri;
}

Future<void> sendSticker(Room room, StickerImg s, {Event? inReplyTo}) async {
  final url = s.url ?? await _builtinMxc(s);
  await room.sendEvent({'body': s.body, 'url': url.toString(), 'info': {...s.info}, ...ttlExtra(room)}, type: EventTypes.Sticker, inReplyTo: inReplyTo);
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
  final double height;
  const EmojiStickerPanel({super.key, required this.room, required this.onEmoji, required this.onSticker, this.height = 300});
  @override
  State<EmojiStickerPanel> createState() => _EmojiStickerPanelState();
}

class _EmojiStickerPanelState extends State<EmojiStickerPanel> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
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

  Widget _stickerTab() {
    final packs = stickerPacks(widget.room);
    return CustomScrollView(slivers: [
      for (final pk in packs) ...[
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), child: Text(pk.name, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)))),
        if (pk.items.isEmpty && pk.own)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text('Долгое нажатие на стикер или фото в чате → «В мои стикеры»', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
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
        TabBar(controller: _tabs, tabs: const [Tab(text: 'Эмодзи', height: 38), Tab(text: 'Стикеры', height: 38)]),
        Expanded(child: TabBarView(controller: _tabs, children: [_emojiTab(), _stickerTab()])),
      ]),
    );
  }
}
