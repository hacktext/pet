import 'dart:convert';
import 'dart:io';

import 'package:aipet/services/account_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late AccountStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('account_');
    store = AccountStore(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  const account = Account(token: '7|secret', user: AccountUser(id: 7, name: '用户1234', phoneMasked: '138****1234'));

  test('nobody signed in at first', () => expect(store.load(), isNull));

  test('save, load in a new store, clear', () {
    store.save(account);
    expect(jsonDecode(store.file.readAsStringSync()), {
      'schema': 1,
      'token': '7|secret',
      'user': {'id': 7, 'name': '用户1234', 'phone_masked': '138****1234'},
    });
    expect(AccountStore(root).load(), account);
    store.clear();
    expect(store.load(), isNull);
    expect(store.file.existsSync(), isFalse);
    store.clear(); // already gone: harmless
  });

  test('an unreadable file is signed out and kept as .bad', () {
    store.file.writeAsStringSync('{"schema":1,"token":5}');
    expect(store.load(), isNull);
    expect(File('${store.file.path}.bad').existsSync(), isTrue);
  });

  test('Account.fromLogin reads the login reply', () {
    final a = Account.fromLogin({
      'token': 't',
      'created': true,
      'user': {'id': 3, 'name': 'n', 'phone_masked': '139****0000'},
    });
    expect(a, const Account(token: 't', user: AccountUser(id: 3, name: 'n', phoneMasked: '139****0000')));
    expect(Account.fromLogin({'token': 't'}), isNull);
    expect(Account.fromLogin('nope'), isNull);
  });
}
