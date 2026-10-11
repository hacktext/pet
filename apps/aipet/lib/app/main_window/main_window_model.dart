import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;

import '../../domain/account_view.dart';
import '../../domain/custom_order.dart';
import '../../domain/library_state.dart';
import '../../domain/pet.dart';
import '../../services/custom_service.dart';
import '../../services/pet_library.dart';
import '../../services/window_bridge.dart';
import 'custom_flow/custom_deps.dart';

/// 我的定制 asks again this often while something is generating and the page
/// is on screen (generation spec 6.2).
const kCustomPollInterval = Duration(seconds: 30);

/// Main-window state. Reads pet folders itself (read-only); everything about
/// who is adopted or on the desktop comes from the pet window (spec 4.3).
class MainWindowModel extends ChangeNotifier {
  MainWindowModel({
    required this._library,
    required this._bridge,
    this.custom,
    this.customPollInterval = kCustomPollInterval,
  });

  final Duration customPollInterval;
  Timer? _customPoll;
  bool _visible = true;

  /// The custom-pet flow's services; null leaves 立即定制 doing nothing.
  final CustomDeps? custom;

  final PetLibrary _library;
  final MainWindowBridge _bridge;
  StreamSubscription<LibraryState>? _sub;
  StreamSubscription<AccountView>? _accountSub;
  StreamSubscription<List<ReadyPet>>? _readySub;
  ReadyPet? _ready;
  final _announced = <String>{}; // a pet is announced once; resends are not news
  bool _disposed = false;

  List<Pet> _pets = const [];
  LibraryState _state = LibraryState.empty;
  Category _category = Category.allPets;
  int _tab = 0;
  String? _message;
  bool _closeFlow = false;
  bool _expiring = false; // a 1003 was handled; the sign-out it asked for is out
  List<CustomRequestInfo> _customs = const [];
  int _customsAsk = 0; // only the newest list request may fill 我的定制

  AccountView _account = AccountView.signedOut;
  bool _accountBusy = false;
  String? _accountError;
  int _codeWait = 0;
  Timer? _codeTimer;

  Category get category => _category;
  Group get group => _category.group;
  int get tab => _tab;
  List<Pet> get plazaPets => filterPets(_pets, _category);
  List<Pet> get minePets => adoptedPets(_pets, _state);

  /// The account card on 我的; the pet window holds the account itself.
  AccountView get account => _account;

  /// A request is out; the card's buttons wait for it.
  bool get accountBusy => _accountBusy;

  /// The last request's failure, in the server's words where it gave any.
  String? get accountError => _accountError;

  /// Seconds until another code may be asked for; 0 when it may now.
  int get codeWait => _codeWait;

  /// 我的定制, newest first; empty when signed out or not loaded yet.
  List<CustomRequestInfo> get customs => _customs;

  /// A custom pet that just arrived (generation spec 6.2): 你的「…」做好了.
  ReadyPet? get readyPet => _ready;

  CardStatus statusOf(Pet p) => cardStatusFor(petId: p.id, complete: p.isComplete, state: _state);

  Future<void> start() async {
    _pets = _library.scan();
    _bridge.start();
    // Before any await: the stream is broadcast and drops what nobody hears.
    _readySub = _bridge.readyPets.listen(_petsArrived);
    var pushed = false;
    _sub = _bridge.states.listen((s) {
      pushed = true;
      _state = s;
      notifyListeners();
    });
    try {
      final s = await _bridge.getState();
      // A push that arrived while we were asking is newer than this reply.
      if (!pushed) _state = s;
    } on BridgeTimeout {
      // The pet window pushes stateChanged whenever something happens; the
      // cards simply start from "nobody adopted" until it does.
    }
    var accountPushed = false;
    _accountSub = _bridge.accounts.listen((a) {
      accountPushed = true;
      _account = a;
      notifyListeners();
      unawaited(loadCustoms());
    });
    final a = await _bridge.getAccount();
    if (a != null && !accountPushed) _account = a;
    // What arrived while this window was closed (may overlap a live push).
    final waiting = await _bridge.takeReady();
    if (_disposed) return;
    _petsArrived(waiting);
    notifyListeners();
  }

  void _petsArrived(List<ReadyPet> ready) {
    if (_disposed) return;
    final fresh = [
      for (final r in ready)
        if (_announced.add(r.petId)) r,
    ];
    if (fresh.isEmpty) return;
    _pets = _library.scan();
    _ready = fresh.last;
    notifyListeners();
    unawaited(loadCustoms());
  }

  void dismissReady() {
    _ready = null;
    notifyListeners();
  }

  /// 换它陪我: the library's usual switch.
  Future<void> adoptReady() async {
    final r = _ready;
    if (r == null) return;
    _ready = null;
    notifyListeners();
    await adopt(r.petId);
  }

  /// Switching group starts over at its 全部.
  void setGroup(Group g) {
    if (g == group) return;
    _category = g.categories.first;
    notifyListeners();
  }

  void setCategory(Category c) {
    _category = c;
    notifyListeners();
  }

  void setTab(int i) {
    _tab = i;
    _updateCustomPoll();
    notifyListeners();
    if (i == 1) unawaited(loadCustoms());
  }

  Future<void> loadCustoms() async {
    final c = custom;
    final ask = ++_customsAsk;
    // Mid sign-out (login expired) there is no one to ask for.
    if (c == null || !_account.signedIn || _expiring) {
      _customs = const [];
      _updateCustomPoll();
      notifyListeners();
      return;
    }
    try {
      final list = await c.service.list();
      // A newer request, or a sign-out, came while this one was out.
      if (_disposed || ask != _customsAsk || !_account.signedIn) return;
      _customs = list;
      // Delivered but not here (yet, or the user deleted it): the pet window
      // is the one that downloads; this window never writes pets/.
      if (list.any(_deliveredButMissing)) _bridge.refreshCustom();
    } on CustomFailure {
      // Keep what was shown; the next visit to 我的 asks again.
      if (_disposed || ask != _customsAsk) return;
    }
    _updateCustomPoll();
    notifyListeners();
  }

  bool _deliveredButMissing(CustomRequestInfo r) =>
      r.status == CustomStatus.delivered &&
      r.petId != null &&
      !(PetLibrary.byId(_pets, r.petId!)?.isComplete ?? false);

  /// The library window is on screen (false while × has hidden it or it is
  /// minimized): 我的定制 only refreshes when someone can see it.
  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    _updateCustomPoll();
  }

  void _updateCustomPoll() {
    final want = !_disposed &&
        _visible &&
        _tab == 1 &&
        _account.signedIn &&
        _customs.any((r) => r.status == CustomStatus.generating);
    if (want) {
      _customPoll ??= Timer.periodic(customPollInterval, (_) => unawaited(loadCustoms()));
    } else {
      _customPoll?.cancel();
      _customPoll = null;
    }
  }

  /// 立即定制 while signed out.
  void requireLogin() {
    _tab = 1;
    _say('请先登录后再定制');
  }

  /// The server no longer takes the token: whatever custom page is open
  /// closes, the pet window is asked to sign out (it owns account.json), and
  /// 我的 says why, showing the sign-in form. Once per expiry: the 1003s that
  /// follow while signing out change nothing.
  void loginExpired() {
    if (_expiring || !_account.signedIn) return;
    _expiring = true;
    _tab = 1;
    _closeFlow = true;
    _say('登录已过期，请重新登录');
    unawaited(logout().whenComplete(() => _expiring = false));
  }

  /// Whether the custom pages are to close; reading it clears it.
  bool takeCloseFlow() {
    final c = _closeFlow;
    _closeFlow = false;
    return c;
  }

  Future<void> adopt(String petId) async {
    try {
      await _bridge.adopt(petId);
    } on AdoptError catch (e) {
      _say(e.code == 'missing_assets' ? '素材缺失' : '切换失败，请重试');
    } on BridgeTimeout {
      _say('切换失败，请重试');
    }
  }

  static final _phonePattern = RegExp(r'^1[3-9]\d{9}$');
  static final _codePattern = RegExp(r'^\d{6}$');

  Future<void> sendCode(String phone) async {
    phone = phone.trim();
    if (_accountBusy || _codeWait > 0) return;
    if (!_phonePattern.hasMatch(phone)) return _accountFailed('请输入正确的手机号');
    final r = await _accountRequest(() => _bridge.sendSms(phone));
    final wait = r.retryAfter;
    if (wait != null && wait > 0) _startCodeWait(wait);
    notifyListeners();
  }

  Future<void> login(String phone, String code) async {
    phone = phone.trim();
    code = code.trim();
    if (_accountBusy) return;
    if (!_phonePattern.hasMatch(phone)) return _accountFailed('请输入正确的手机号');
    if (!_codePattern.hasMatch(code)) return _accountFailed('请输入6位验证码');
    final r = await _accountRequest(() => _bridge.login(phone, code));
    if (r.ok) {
      _stopCodeWait();
      // The pet window has pushed it already, unless the push lost the race.
      final a = await _bridge.getAccount();
      if (a != null) _account = a;
    }
    notifyListeners();
  }

  Future<void> logout() async {
    if (_accountBusy) return;
    await _accountRequest(_bridge.logout);
    _account = AccountView.signedOut;
    _accountError = null;
    _customsAsk++;
    _customs = const [];
    _updateCustomPoll();
    notifyListeners();
  }

  Future<void> syncNow() async {
    if (_accountBusy) return;
    final r = await _accountRequest(_bridge.syncNow);
    if (r.ok) _say('同步完成');
    notifyListeners();
  }

  Future<AccountReply> _accountRequest(Future<AccountReply> Function() call) async {
    _accountBusy = true;
    _accountError = null;
    notifyListeners();
    final r = await call();
    _accountBusy = false;
    _accountError = r.ok ? null : r.message;
    return r;
  }

  void _accountFailed(String m) {
    _accountError = m;
    notifyListeners();
  }

  void _startCodeWait(int seconds) {
    _codeTimer?.cancel();
    _codeWait = seconds;
    _codeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _codeWait--;
      if (_codeWait <= 0) _stopCodeWait();
      notifyListeners();
    });
  }

  void _stopCodeWait() {
    _codeTimer?.cancel();
    _codeTimer = null;
    _codeWait = 0;
  }

  /// A one-shot message for a SnackBar; reading it clears it.
  String? takeMessage() {
    final m = _message;
    _message = null;
    return m;
  }

  void quit() => _bridge.quit();

  Future<void> closing() => _bridge.notifyClosing();

  void _say(String m) {
    _message = m;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _customPoll?.cancel();
    _customPoll = null;
    _sub?.cancel();
    _accountSub?.cancel();
    _readySub?.cancel();
    _stopCodeWait();
    _bridge.dispose();
    super.dispose();
  }
}
