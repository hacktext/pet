import 'package:aipet/domain/account_view.dart';
import 'package:aipet/services/window_bridge.dart';

/// The pet window's account side, scripted: [calls] records each request.
class FakeAccount implements AccountHandler {
  @override
  AccountView view = AccountView.signedOut;
  final calls = <String>[];
  bool fail = false;

  AccountReply smsReply = const AccountReply(ok: false, message: '发送太频繁', retryAfter: 42);
  AccountReply loginReply = const AccountReply(ok: true);
  AccountReply syncReply = const AccountReply(ok: true);

  /// What a successful login turns [view] into.
  AccountView signedInAs = const AccountView(phoneMasked: '138****1234', name: '用户1234');

  @override
  Future<AccountReply> sendSms(String phone) async {
    calls.add('sms $phone');
    return smsReply;
  }

  @override
  Future<AccountReply> login(String phone, String code) async {
    if (fail) throw StateError('bug');
    calls.add('login $phone $code');
    if (loginReply.ok) view = signedInAs;
    return loginReply;
  }

  @override
  Future<void> logout() async {
    calls.add('logout');
    view = AccountView.signedOut;
  }

  @override
  Future<AccountReply> syncNow() async {
    calls.add('sync');
    return syncReply;
  }
}
