// Кэш в памяти с ограничением: хранит последние N записей, старые вытесняются.
// Без ограничения картинки копились бы бесконечно и на слабых телефонах приложение закрывалось.
import 'dart:collection';

class Lru<K, V> {
  final int max;
  final _m = LinkedHashMap<K, V>();
  Lru(this.max);

  V? operator [](K k) {
    final v = _m.remove(k);
    if (v != null) _m[k] = v; // свежее — в конец
    return v;
  }

  void operator []=(K k, V v) {
    _m.remove(k);
    _m[k] = v;
    while (_m.length > max) {
      _m.remove(_m.keys.first);
    }
  }

  bool containsKey(K k) => _m.containsKey(k);
  V? remove(K k) => _m.remove(k);

  V putIfAbsent(K k, V Function() make) {
    final v = this[k];
    if (v != null) return v;
    final n = make();
    this[k] = n;
    return n;
  }

  void clear() => _m.clear();
  int get length => _m.length;
}

/// Все кэши приложения — чтобы очистить разом («Хранилище → Очистить кэш»).
final List<void Function()> memoryCaches = [];
void clearMemoryCaches() {
  for (final c in memoryCaches) {
    c();
  }
}

extension RegisterCache<K, V> on Lru<K, V> {
  /// Зарегистрировать кэш для общей очистки.
  void register() => memoryCaches.add(clear);
}
