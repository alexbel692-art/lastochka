// Имена в чате: тёзку (в том числе «Иван» с латинской «а» или с невидимым символом) видно по логину.
import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/chat/names.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

StrippedStateEvent _member(String id, String name) => StrippedStateEvent(
      type: EventTypes.RoomMember,
      stateKey: id,
      senderId: id,
      content: {'membership': 'join', 'displayname': name},
    );

void main() {
  test('ключ имени: регистр, пробелы, латинские двойники, невидимые символы', () {
    expect(nameKey('Иван  Петров'), nameKey('иван петров'));
    expect(nameKey('Ивaн'), nameKey('Иван')); // латинская «a»
    expect(nameKey('Иван\u200b'), nameKey('Иван'));
    expect(nameKey('Иван'), isNot(nameKey('Иванов')));
    expect(cleanName('Бос\u202Eс'), 'Босс');
  });

  test('тёзки в группе показываются с адресом, остальные — просто по имени', () async {
    sqfliteFfiInit();
    final db = await MatrixSdkDatabase.init('names_test', database: await createDatabaseFactoryFfi().openDatabase(':memory:'));
    final c = Client('names_test', database: db);
    final room = Room(id: '!g:test', client: c);
    room.setState(_member('@boss:test', 'Директор'));
    room.setState(_member('@eve:evil.test', 'Дирeктор')); // латинская «e»
    room.setState(_member('@ann:test', 'Анна'));
    expect(memberName(room, '@ann:test'), 'Анна');
    expect(memberName(room, '@boss:test'), contains('@boss'));
    expect(memberName(room, '@eve:evil.test'), contains('@eve:evil.test'));
    // самозванец ушёл — подписи пропадают
    room.setState(StrippedStateEvent(type: EventTypes.RoomMember, stateKey: '@eve:evil.test', senderId: '@eve:evil.test', content: {'membership': 'leave'}));
    expect(memberName(room, '@boss:test'), 'Директор');
  });
}
