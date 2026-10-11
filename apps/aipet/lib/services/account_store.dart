import 'dart:convert';
import 'dart:io';

import 'json_file.dart';

/// `user` in the server's replies: `{id, name, phone_masked}`.
class AccountUser {
  const AccountUser({required this.id, required this.name, required this.phoneMasked});

  final int id;
  final String name;
  final String phoneMasked;

  static AccountUser? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'], phone = j['phone_masked'];
    if (id is! int || name is! String || phone is! String) return null;
    return AccountUser(id: id, name: name, phoneMasked: phone);
  }

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'phone_masked': phoneMasked};

  @override
  bool operator ==(Object other) =>
      other is AccountUser && other.id == id && other.name == name && other.phoneMasked == phoneMasked;

  @override
  int get hashCode => Object.hash(id, name, phoneMasked);
}

/// Who is signed in on this computer, and the token that says so.
class Account {
  const Account({required this.token, required this.user});

  final String token;
  final AccountUser user;

  /// The `data` of a successful login: `{token, created, user}`; null when it is not that.
  static Account? fromLogin(Object? data) {
    if (data is! Map) return null;
    final token = data['token'];
    final user = AccountUser.fromJson(data['user']);
    if (token is! String || token.isEmpty || user == null) return null;
    return Account(token: token, user: user);
  }

  @override
  bool operator ==(Object other) => other is Account && other.token == token && other.user == user;

  @override
  int get hashCode => Object.hash(token, user);
}

/// account.json `{schema: 1, token, user}`. Only the pet window writes it.
class AccountStore {
  AccountStore(this.root);

  final Directory root;

  File get file => File('${root.path}${Platform.pathSeparator}account.json');

  /// Never throws: missing is signed out; unreadable is signed out and kept as .bad.
  Account? load() {
    if (!file.existsSync()) return null;
    try {
      final j = jsonDecode(file.readAsStringSync());
      if (j is! Map<String, Object?> || j['schema'] != 1) throw const FormatException('bad schema');
      final a = Account.fromLogin(j);
      if (a == null) throw const FormatException('bad account');
      return a;
    } catch (e) {
      quarantine(file, 'aipet.account', e);
      return null;
    }
  }

  /// The token for the library window, which only reads (the pet window is the
  /// one writer): null on anything unexpected, and the file is left alone.
  String? readToken() {
    try {
      final j = jsonDecode(file.readAsStringSync());
      final t = j is Map ? j['token'] : null;
      return t is String && t.isNotEmpty ? t : null;
    } catch (_) {
      return null;
    }
  }

  void save(Account a) => writeJsonAtomic(file, {'schema': 1, 'token': a.token, 'user': a.user.toJson()});

  void clear() {
    if (file.existsSync()) file.deleteSync();
  }
}
