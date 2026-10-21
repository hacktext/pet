import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' hide Category;

import '../../domain/account_view.dart';
import '../../domain/custom_order.dart';
import '../../domain/library_state.dart';
import '../../domain/paid_character.dart';
import '../../domain/pet.dart';
import '../../services/catalog_store.dart';
import '../../services/character_service.dart';
import '../../services/custom_service.dart';
import '../../services/file_download.dart';
import '../../services/pet_library.dart';
import '../../services/voice_store.dart';
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
    this.characters,
    this.catalogStore,
    this.cardTransport,
  });

  /// The shop's catalog; null shows the free pets only.
  final CharacterService? characters;

  /// The cached catalog and card photos; null caches nothing. This window
  /// writes catalog.json and cards/ only -- owned.json is the pet window's.
  final CatalogStore? catalogStore;

  /// Fetches the card photos into [catalogStore]; null leaves them uncached.
  final DownloadTransport? cardTransport;

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
  StreamSubscription<VoiceChoices>? _voiceSub;
  StreamSubscription<Set<String>>? _ownedSub;
  StreamSubscription<({String code, int done, int total})>? _progressSub;
  List<PaidCharacter> _catalog = const [];
  Set<String> _owned = const {};
  Map<String, double> _downloading = const {};
  VoiceChoices _voices = const {};
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

  /// The free pets of the category, then its paid characters in catalog
  /// order: installed and owned as [InstalledEntry], the rest as
  /// [RemoteEntry]. Owned, installed characters the catalog does not list
  /// (it was never fetched) follow.
  List<PlazaEntry> get plazaPets {
    final inCategory = filterPets(_pets, _category);
    final listed = {for (final c in _catalog) c.petId};
    return [
      for (final p in inCategory)
        if (p.origin != PetOrigin.paid) InstalledEntry(p),
      for (final c in _catalog)
        if (_inCategory(c.species))
          paidStateOf(c.code) == PaidState.installed ? InstalledEntry(_installed(c.code)!) : RemoteEntry(c),
      for (final p in inCategory)
        if (p.origin == PetOrigin.paid && !listed.contains(p.id) && paidStateOf(codeOf(p)!) == PaidState.installed)
          InstalledEntry(p),
    ];
  }

  bool _inCategory(Species s) => _category.species == null ? Group.of(s) == _category.group : s == _category.species;

  List<Pet> get minePets => adoptedPets(_pets, _state);

  /// Any pet in the library, by id; null when there is none.
  Pet? petById(String id) => PetLibrary.byId(_pets, id);

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

  /// The paid characters the shop sells, as last fetched or cached.
  List<PaidCharacter> get catalog => _catalog;

  /// The codes the account owns, as the pet window says.
  Set<String> get owned => _owned;

  /// Downloads under way: code to progress, 0..1.
  Map<String, double> get downloading => _downloading;

  /// The catalog's [code]; null when it is not (or no longer) listed.
  PaidCharacter? characterOf(String code) => _catalog.where((c) => c.code == code).firstOrNull;

  /// A paid pet's code (`paid-<code>`); null for any other pet.
  static String? codeOf(Pet p) => p.origin == PetOrigin.paid && p.id.startsWith('paid-') ? p.id.substring(5) : null;

  /// `paid-<code>` when it is on disk whole; a half-installed folder is still
  /// to be downloaded (the download picks up where it stopped).
  Pet? _installed(String code) {
    final p = PetLibrary.byId(_pets, 'paid-$code');
    return p != null && p.isComplete ? p : null;
  }

  PaidState paidStateOf(String code) {
    if (_downloading.containsKey(code)) return PaidState.downloading;
    if (!_owned.contains(code)) return PaidState.locked;
    return _installed(code) != null ? PaidState.installed : PaidState.owned;
  }

  /// 「¥… 解锁」. A no-op stub: Task C6 (the payment flow) replaces it.
  Future<void> unlock(PaidCharacter c) async {}

  /// 「下载」: the pet window downloads and installs `paid-<code>`, sending
  /// progress; this window rescans once it is there.
  Future<void> download(String code) async {
    if (_downloading.containsKey(code)) return;
    _downloading = {..._downloading, code: 0};
    notifyListeners();
    final ok = await _bridge.downloadCharacter(code);
    if (_disposed) return;
    _downloading = {..._downloading}..remove(code);
    if (ok) {
      _pets = _library.scan();
      notifyListeners();
    } else {
      _say('下载失败，请重试');
    }
  }

  void _progressed(({String code, int done, int total}) p) {
    if (_disposed || !_downloading.containsKey(p.code) || p.total <= 0) return;
    _downloading = {..._downloading, p.code: (p.done / p.total).clamp(0.0, 1.0)};
    notifyListeners();
  }

  Future<void> _loadOwned() async {
    final o = await _bridge.getOwned();
    if (_disposed || o == null) return;
    _owned = o;
    notifyListeners();
  }

  /// The cached catalog, before the first frame; owned.json stands in until
  /// the pet window answers.
  void _loadCachedCatalog() {
    final cached = catalogStore?.load();
    if (cached == null) return;
    _catalog = cached.items;
    _owned = cached.owned;
  }

  /// The shop's catalog, in the background. A failure keeps the cache and
  /// says nothing: the free pets are the library either way.
  Future<void> _fetchCatalog() async {
    final service = characters;
    if (service == null) return;
    final List<PaidCharacter> items;
    try {
      items = await service.catalog();
    } catch (e) {
      developer.log('catalog not fetched ($e); keeping the cache', name: 'aipet.catalog');
      return;
    }
    if (_disposed) return;
    _catalog = items;
    notifyListeners();
    final store = catalogStore;
    if (store == null) return;
    try {
      store.save(items);
    } catch (e) {
      developer.log('catalog not saved ($e)', name: 'aipet.catalog');
    }
    final t = cardTransport;
    if (t == null) return;
    for (final c in items) {
      final had = store.cardFile(c.code).existsSync();
      await store.cacheCard(c, t);
      if (_disposed) return;
      if (!had && store.cardFile(c.code).existsSync()) notifyListeners(); // its photo landed
    }
  }

  CardStatus statusOf(Pet p) => cardStatusFor(petId: p.id, complete: p.isComplete, state: _state);

  /// The voice [p] speaks in, null for 静音 -- which is also every
  /// character's start, as in the pet window.
  String? voiceOf(Pet p) {
    final chosen = _voices[p.id];
    return p.voices.any((v) => v.id == chosen) ? chosen : null;
  }

  /// From a character card: [voice] for [p], null for 静音. Shown at once;
  /// the pet window, which keeps voice.json, confirms with the full list.
  Future<void> chooseVoice(Pet p, String? voice) async {
    _voices = {..._voices, p.id: voice ?? kVoiceOff};
    notifyListeners();
    final confirmed = await _bridge.chooseVoice(p.id, voice);
    if (_disposed) return;
    if (confirmed == null) {
      _say('设置失败，请重试');
      unawaited(_loadVoices());
      return;
    }
    _voices = confirmed;
    notifyListeners();
  }

  Future<void> _loadVoices() async {
    final v = await _bridge.getVoices();
    if (_disposed || v == null) return;
    _voices = v;
    notifyListeners();
  }

  Future<void> start() async {
    _pets = _library.scan();
    _loadCachedCatalog();
    _bridge.start();
    // Before any await: the stream is broadcast and drops what nobody hears.
    _readySub = _bridge.readyPets.listen(_petsArrived);
    _ownedSub = _bridge.owned.listen((o) {
      if (_disposed) return;
      _owned = o;
      notifyListeners();
    });
    _progressSub = _bridge.characterProgress.listen(_progressed);
    unawaited(_fetchCatalog());
    _voiceSub = _bridge.voices.listen((v) {
      if (_disposed) return;
      _voices = v;
      notifyListeners();
    });
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
    await _loadVoices();
    await _loadOwned();
    // What arrived while this window was closed (may overlap a live push).
    final waiting = await _bridge.takeReady();
    if (_disposed) return;
    _petsArrived(waiting);
    notifyListeners();
  }

  void _petsArrived(List<ReadyPet> ready) {
    if (_disposed) return;
    if (ready.isEmpty) return;
    // Announcing is once per pet; listing is every time (the folder may have
    // been deleted and has come back).
    final fresh = [
      for (final r in ready)
        if (_announced.add(r.petId)) r,
    ];
    _pets = _library.scan();
    if (fresh.isNotEmpty) _ready = fresh.last;
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
      // An order nobody paid for is not shown: leaving the plans page unpaid
      // leaves no trace in 我的定制, and a new 立即定制 starts over.
      _customs = [for (final r in list) if (!r.status.awaitingPayment) r];
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
    if (visible) {
      unawaited(_loadVoices()); // a voice may have changed from the pet's menu meanwhile
      unawaited(_loadOwned()); // and what is owned (a sign-out, a refund)
    }
  }

  void _updateCustomPoll() {
    final want = !_disposed &&
        _visible &&
        _tab == 1 &&
        _account.signedIn &&
        _customs.any((r) => r.status.inProgress);
    if (want) {
      _customPoll ??= Timer.periodic(customPollInterval, (_) => unawaited(loadCustoms()));
    } else {
      _customPoll?.cancel();
      _customPoll = null;
    }
  }

  /// 立即定制 while signed out: 我的 behind the sign-in page it opens.
  void requireLogin() {
    _tab = 1;
    notifyListeners();
  }

  /// A fresh sign-in page starts without the last attempt's error.
  void clearAccountError() {
    if (_accountError == null) return;
    _accountError = null;
    notifyListeners();
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
    _voiceSub?.cancel();
    _ownedSub?.cancel();
    _progressSub?.cancel();
    _stopCodeWait();
    _bridge.dispose();
    super.dispose();
  }
}
