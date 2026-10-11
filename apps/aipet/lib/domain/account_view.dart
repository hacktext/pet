/// The account as the library's 我的 page shows it. Travels over the window
/// channel as [toJson]; the token never leaves the pet window.
class AccountView {
  const AccountView({this.phoneMasked, this.name, this.lastSyncAt, this.syncing = false});

  static const signedOut = AccountView();

  /// 138****1234; null when nobody is signed in.
  final String? phoneMasked;
  final String? name;
  final DateTime? lastSyncAt;
  final bool syncing;

  bool get signedIn => phoneMasked != null;

  Map<String, Object?> toJson() => {
        'phoneMasked': phoneMasked,
        'name': name,
        'lastSyncAt': lastSyncAt?.millisecondsSinceEpoch,
        'syncing': syncing,
      };

  factory AccountView.fromJson(Map<Object?, Object?> j) {
    final last = j['lastSyncAt'];
    return AccountView(
      phoneMasked: j['phoneMasked'] as String?,
      name: j['name'] as String?,
      lastSyncAt: last is int ? DateTime.fromMillisecondsSinceEpoch(last) : null,
      syncing: j['syncing'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AccountView &&
      other.phoneMasked == phoneMasked &&
      other.name == name &&
      other.lastSyncAt == lastSyncAt &&
      other.syncing == syncing;

  @override
  int get hashCode => Object.hash(phoneMasked, name, lastSyncAt, syncing);

  @override
  String toString() => 'AccountView(${toJson()})';
}

/// How an account request (send code, sign in, sync) went: [message] is the
/// server's own words on failure; [retryAfter] is how long until another code
/// may be asked for.
class AccountReply {
  const AccountReply({required this.ok, this.message = '', this.retryAfter});

  final bool ok;
  final String message;
  final int? retryAfter;

  Map<String, Object?> toJson() => {'ok': ok, 'message': message, 'retryAfter': retryAfter};

  factory AccountReply.fromJson(Map<Object?, Object?> j) => AccountReply(
        ok: j['ok'] == true,
        message: (j['message'] as String?) ?? '',
        retryAfter: j['retryAfter'] as int?,
      );
}
