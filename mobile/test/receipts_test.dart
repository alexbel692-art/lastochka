// Прочтение в Element (отметка «основная лента», MSC3771) тоже даёт две галочки.
import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/chat/receipts.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('отметки из общей и из основной ленты учитываются обе, берётся самая поздняя', () async {
    sqfliteFfiInit();
    final db = await MatrixSdkDatabase.init('receipts_test', database: await createDatabaseFactoryFfi().openDatabase(':memory:'));
    final c = Client('receipts_test', database: db);
    final room = Room(id: '!r:test', client: c);
    room.receiptState = LatestReceiptState.fromJson({
      'global': {
        'others': {
          '@old:test': {'e': '\$a', 'ts': 100},
        },
      },
      'main': {
        'others': {
          '@element:test': {'e': '\$b', 'ts': 500},
          '@old:test': {'e': '\$c', 'ts': 300},
        },
      },
    });
    final r = otherReadReceipts(room);
    expect(r.keys, containsAll(['@old:test', '@element:test']));
    expect(r['@old:test']!.ts, 300);
    expect(readByOthersSince(room, 450), isTrue); // прочитал только тот, кто в Element
    expect(readByOthersSince(room, 600), isFalse);
  });
}
