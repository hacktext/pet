import 'package:flutter/material.dart';

import '../../domain/account_view.dart';
import '../../domain/custom_order.dart';
import '../../domain/library_state.dart';
import '../../domain/pet.dart';
import '../../services/window_bridge.dart';
import 'custom_flow/custom_form_page.dart';
import 'custom_flow/pay_page.dart';
import 'custom_flow/plan_page.dart';
import 'custom_flow/submitted_page.dart';
import 'login_page.dart';
import 'main_window_model.dart';
import 'pet_card.dart';
import 'theme.dart';

/// The page's side margin, right of the sidebar.
const double _gutter = 28;

class MainWindowApp extends StatefulWidget {
  const MainWindowApp({super.key, required this.model});

  final MainWindowModel model;

  @override
  State<MainWindowApp> createState() => _MainWindowAppState();
}

class _MainWindowAppState extends State<MainWindowApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_showMessage);
  }

  @override
  void dispose() {
    widget.model.removeListener(_showMessage);
    super.dispose();
  }

  void _showMessage() {
    if (widget.model.takeCloseFlow()) _navigator.currentState?.popUntil((r) => r.isFirst);
    final m = widget.model.takeMessage();
    if (m != null) _messenger.currentState?.showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'aipet',
      theme: buildAppTheme(),
      scaffoldMessengerKey: _messenger,
      navigatorKey: _navigator,
      home: ListenableBuilder(
        listenable: model,
        builder: (context, _) => Scaffold(
          body: SafeArea(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Sidebar(model: model),
              Expanded(
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_gutter, 24, _gutter, 0),
                    child: _TopBar(model: model),
                  ),
                  if (model.readyPet case final ready?)
                    _ReadyBanner(pet: ready, onAdopt: model.adoptReady, onDismiss: model.dismissReady),
                  Expanded(child: model.tab == 0 ? _PlazaPage(model: model) : _MinePage(model: model)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// aipet 桌面陪伴, 发现 / 我的, and at the bottom a way into 定制.
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) => Container(
        width: 232,
        decoration: const BoxDecoration(
          color: AppColors.sidebar,
          border: Border(right: BorderSide(color: AppColors.line)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('aipet',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: AppColors.text, height: 1)),
              SizedBox(height: 8),
              Text('桌面陪伴', style: TextStyle(fontSize: 14, color: AppColors.textMuted)),
            ]),
          ),
          const SizedBox(height: 36),
          _NavItem(icon: Icons.home_outlined, label: '发现', selected: model.tab == 0, onTap: () => model.setTab(0)),
          const SizedBox(height: 8),
          _NavItem(
              icon: Icons.favorite_border, label: '我的', selected: model.tab == 1, onTap: () => model.setTab(1)),
          const Spacer(),
          _Invite(model: model),
        ]),
      );
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.icon, required this.label, required this.selected, required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : AppColors.text;
    return Material(
      color: selected ? AppColors.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(children: [
            Icon(icon, color: fg, size: 24),
            const SizedBox(width: 16),
            Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: fg)),
          ]),
        ),
      ),
    );
  }
}

/// 让喜欢的TA住进你的桌面 →, under a pet of the chosen group peeking over it.
class _Invite extends StatelessWidget {
  const _Invite({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) {
    final mascot = model.petById(model.group == Group.pets ? 'builtin-ragdoll' : 'builtin-xiaoya');
    return Stack(clipBehavior: Clip.none, children: [
      Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => openCustomFlow(context, model),
          child: Padding(
            padding: EdgeInsets.fromLTRB(18, mascot == null ? 18 : 64, 14, 18),
            child: Row(children: [
              const Expanded(
                child: Text('让喜欢的TA\n住进你的桌面',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.text, height: 1.6)),
              ),
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                child: const Icon(Icons.arrow_forward, color: Colors.white, size: 18),
              ),
            ]),
          ),
        ),
      ),
      if (mascot != null)
        Positioned(
          left: 12,
          top: -44,
          height: 100,
          child: IgnorePointer(child: _mascot(mascot)),
        ),
    ]);
  }

  /// An animal's cutout stands on the card; a person's full-length cutout
  /// is too small to read, so a person shows as a round close-up instead.
  Widget _mascot(Pet p) {
    Widget none(_, _, _) => const SizedBox();
    final card = p.cardFile;
    if (!p.species.isCharacter || card == null) {
      return Image.file(p.coverFile, fit: BoxFit.contain, errorBuilder: none);
    }
    return Container(
      width: 88,
      height: 88,
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.card, width: 4),
        boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: ClipOval(child: Image.file(card, fit: BoxFit.cover, cacheWidth: 640, errorBuilder: none)),
    );
  }
}

/// 宠物 | 人物 on 发现 (我的 on its own page), and the account on the right.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 56,
        child: Row(children: [
          if (model.tab == 0)
            _GroupSwitch(model: model)
          else
            const Text('我的', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: AppColors.text)),
          const Spacer(),
          _AccountChip(model: model),
        ]),
      );
}

/// 宠物 | 人物: one pill split in two, the chosen half black.
class _GroupSwitch extends StatelessWidget {
  const _GroupSwitch({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(28)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final g in Group.values)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => model.setGroup(g),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 150,
                height: 48,
                decoration: BoxDecoration(
                  color: model.group == g ? AppColors.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(g == Group.pets ? Icons.pets : Icons.person_outline,
                      size: 22, color: model.group == g ? Colors.white : AppColors.text),
                  const SizedBox(width: 10),
                  Text(
                    g.label,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: model.group == g ? Colors.white : AppColors.text,
                    ),
                  ),
                ]),
              ),
            ),
        ]),
      );
}

/// Signed in: the masked phone, opening 我的; signed out: 登录.
class _AccountChip extends StatelessWidget {
  const _AccountChip({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) {
    final a = model.account;
    final signedIn = a.signedIn;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        key: const Key('account-chip'),
        borderRadius: BorderRadius.circular(28),
        onTap: () => signedIn ? model.setTab(1) : openLogin(context, model),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const CircleAvatar(
              radius: 22,
              backgroundColor: AppColors.accentSoft,
              child: Icon(Icons.person, color: AppColors.textMuted),
            ),
            const SizedBox(width: 10),
            Text(signedIn ? a.phoneMasked ?? '我的' : '登录',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.text)),
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_down, size: 20, color: AppColors.text),
          ]),
        ),
      ),
    );
  }
}

/// The grid of [pets]: as many ~220 px columns as fit, each card's photo a
/// little wider than tall.
class _PetGrid extends StatelessWidget {
  const _PetGrid({required this.model, required this.pets});

  final MainWindowModel model;
  final List<Pet> pets;

  static const _gap = 18.0;

  @override
  Widget build(BuildContext context) => SliverPadding(
        padding: const EdgeInsets.fromLTRB(_gutter, 16, _gutter, 28),
        sliver: SliverLayoutBuilder(builder: (context, c) {
          final width = c.crossAxisExtent;
          final cols = (width / 220).floor().clamp(2, 6);
          final cardWidth = (width - _gap * (cols - 1)) / cols;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: _gap,
              crossAxisSpacing: _gap,
              // photo (card width less padding, 1.15 : 1) + name, tags, button
              mainAxisExtent: (cardWidth - 16) / 1.15 + 138,
            ),
            delegate: SliverChildListDelegate([
              for (final p in pets) PetCard(pet: p, status: model.statusOf(p), onAdopt: () => model.adopt(p.id)),
            ]),
          );
        }),
      );
}

class _PlazaPage extends StatelessWidget {
  const _PlazaPage({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) {
    final pets = model.plazaPets;
    return CustomScrollView(slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(_gutter, 20, _gutter, 0),
        sliver: SliverToBoxAdapter(
            child: _Banner(group: model.group, onCustom: () => openCustomFlow(context, model))),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(_gutter, 20, _gutter, 0),
        sliver: SliverToBoxAdapter(
          child: Wrap(spacing: 12, runSpacing: 8, children: [
            for (final c in model.group.categories)
              _CategoryPill(label: c.label, selected: model.category == c, onTap: () => model.setCategory(c)),
          ]),
        ),
      ),
      if (pets.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('这里还没有小伙伴', style: TextStyle(color: AppColors.textMuted))),
        )
      else
        _PetGrid(model: model, pets: pets),
    ]);
  }
}

class _CategoryPill extends StatelessWidget {
  const _CategoryPill({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? AppColors.accent : AppColors.card,
        shape: StadiumBorder(side: BorderSide(color: selected ? AppColors.accent : AppColors.line)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 112),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 11),
            child: Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : AppColors.text,
                )),
          ),
        ),
      );
}

/// 定制专属宠物 / 定制专属人物 over a photo of the group's own.
class _Banner extends StatelessWidget {
  const _Banner({required this.group, required this.onCustom});

  final Group group;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    final (title, subtitle, scribble, art, icon) = switch (group) {
      Group.pets => ('定制专属宠物', '上传你的爱宠照片，生成会陪伴你的桌面伙伴', '把爱宠带进你的桌面~', 'banner-pets', Icons.pets),
      Group.people => ('定制专属人物', '上传你的照片，生成会陪伴你的桌面伙伴', '把喜欢的TA带进你的桌面~', 'banner-people', Icons.person),
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: SizedBox(
        height: 268,
        child: Stack(fit: StackFit.expand, children: [
          Image.asset('assets/ui/$art.jpg',
              fit: BoxFit.cover,
              alignment: const Alignment(0.6, -0.2),
              errorBuilder: (_, _, _) => const ColoredBox(color: AppColors.warmSoft)),
          // The words sit on the photo's soft left; this keeps them legible.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xE6FFFFFF), Color(0x99FFFFFF), Color(0x00FFFFFF)],
                stops: [0, 0.38, 0.62],
              ),
            ),
          ),
          Align(
            // Between the button and the photo; the person stands further left than the corgi.
            alignment: Alignment(group == Group.pets ? -0.1 : -0.24, 0.62),
            child: Transform.rotate(
              angle: -0.13,
              child: Text(scribble,
                  style: const TextStyle(
                    fontSize: 22,
                    fontStyle: FontStyle.italic,
                    fontWeight: FontWeight.w600,
                    color: AppColors.warm,
                    letterSpacing: 1,
                  )),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 32, 24, 32),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(color: AppColors.warmSoft, borderRadius: BorderRadius.circular(16)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 16, color: AppColors.text),
                  const SizedBox(width: 6),
                  const Text('AI 定制桌面伙伴',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.text)),
                ]),
              ),
              const SizedBox(height: 14),
              Text(title,
                  style: const TextStyle(
                      fontSize: 40, fontWeight: FontWeight.w900, color: AppColors.text, height: 1.15, letterSpacing: 2)),
              const SizedBox(height: 10),
              Text(subtitle, style: const TextStyle(fontSize: 16, color: Color(0xFF4A4541))),
              const Spacer(),
              SizedBox(
                height: 48,
                child: FilledButton(
                  onPressed: onCustom,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 28)),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('立即定制', style: TextStyle(fontSize: 17)),
                    SizedBox(width: 10),
                    Icon(Icons.arrow_forward, size: 20),
                  ]),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _MinePage extends StatelessWidget {
  const _MinePage({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) {
    final pets = model.minePets;
    // One scroll for the whole page: up to 50 orders must not overflow it.
    return Column(children: [
      Expanded(
        child: CustomScrollView(slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(_gutter, 20, _gutter, 0),
            sliver: SliverToBoxAdapter(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: _AccountCard(model: model),
                ),
              ),
            ),
          ),
          if (model.account.signedIn && model.customs.isNotEmpty) _CustomList(model: model),
          const SliverPadding(
            padding: EdgeInsets.fromLTRB(_gutter, 28, _gutter, 0),
            sliver: SliverToBoxAdapter(
              child: Text('我领养的', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
          ),
          if (pets.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('还没有领养小伙伴，去广场看看吧', style: TextStyle(color: AppColors.textMuted))),
              ),
            )
          else
            _PetGrid(model: model, pets: pets),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(_gutter, 0, _gutter, 20),
        child: Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: model.quit,
            icon: const Icon(Icons.power_settings_new, size: 18),
            label: const Text('退出程序'),
          ),
        ),
      ),
    ]);
  }
}

/// 立即定制 → form → plans → pay → submitted (custom order spec 3).
void openCustomFlow(BuildContext context, MainWindowModel model) {
  final deps = model.custom;
  if (deps == null) return;
  if (!model.account.signedIn) {
    model.requireLogin();
    openLogin(context, model, reason: '登录后即可定制你的专属宠物');
    return;
  }
  Navigator.of(context)
      .push(narrowRoute<void>(
        builder: (_) => CustomFormPage(
          deps: deps,
          onSubmitted: (ctx, request) => openPlans(ctx, model, request),
        ),
      ))
      .then((_) => model.loadCustoms()); // however the flow closed
}

/// The plans for [request], then its QR; once paid, 定制已提交, whose button
/// closes the flow onto 我的.
void openPlans(BuildContext context, MainWindowModel model, CustomRequestInfo request) {
  final deps = model.custom;
  if (deps == null) return;
  Widget submitted() => SubmittedPage(onDone: (doneCtx) {
        Navigator.of(doneCtx).popUntil((r) => r.isFirst);
        model.setTab(1);
      });
  Navigator.of(context)
      .push(narrowRoute<void>(
    builder: (_) => PlanPage(
      deps: deps,
      request: request,
      onAlreadyPaid: (ctx) =>
          Navigator.of(ctx).pushReplacement(narrowRoute<void>(builder: (_) => submitted())),
      onOrder: (ctx, plan, order) => Navigator.of(ctx).push(narrowRoute<void>(
        builder: (_) => PayPage(
          deps: deps,
          request: request,
          plan: plan,
          order: order,
          onPaid: (payCtx) => Navigator.of(payCtx).pushReplacement(narrowRoute<void>(
            builder: (_) => submitted(),
          )),
        ),
      )),
    ),
  ))
      .then((_) => model.loadCustoms());
}

/// 我的定制: each paid order's first photo, name, category, plan and
/// progress. A sliver, so up to 50 rows build only as they scroll into view.
class _CustomList extends StatelessWidget {
  const _CustomList({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) {
    final rows = model.customs;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(_gutter, 24, _gutter, 0),
      sliver: SliverList.builder(
        itemCount: rows.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('我的定制', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            );
          }
          final r = rows[i - 1];
          return Card(
            color: AppColors.card,
            child: ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: r.coverUrl == null
                      ? const Icon(Icons.pets, color: AppColors.accent)
                      : Image.network(r.coverUrl!,
                          fit: BoxFit.cover,
                          cacheWidth: 96,
                          cacheHeight: 96,
                          errorBuilder: (_, _, _) => const Icon(Icons.pets, color: AppColors.accent)),
                ),
              ),
              title: Text(r.name),
              subtitle: Text([speciesLabel(r.species), ?r.planName].join(' · ')),
              trailing: Text(r.statusText,
                  style: TextStyle(
                    color: r.status == CustomStatus.failed ? Colors.redAccent : AppColors.accent,
                    fontWeight: FontWeight.w700,
                  )),
            ),
          );
        },
      ),
    );
  }
}

/// Signed out, 登录 / 注册 opening the sign-in page; signed in, the account,
/// its last sync, 立即同步 and 退出登录 (web platform spec 8). The pet window
/// does the work; this only asks.
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.model});

  final MainWindowModel model;

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _syncLine(AccountView a) {
    if (a.syncing) return '同步中…';
    final t = a.lastSyncAt;
    if (t == null) return '尚未同步';
    return '上次同步：${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final a = model.account;
    if (!a.signedIn) return _SignInEntry(onTap: () => openLogin(context, model));
    final error = model.accountError;
    final busy = model.accountBusy;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const CircleAvatar(
            backgroundColor: AppColors.accentSoft,
            child: Icon(Icons.person, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.phoneMasked!,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.text)),
              const SizedBox(height: 2),
              Text(_syncLine(a), style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: busy || a.syncing ? null : model.syncNow,
              child: const Text('立即同步'),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: busy ? null : model.logout, child: const Text('退出登录')),
        ]),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
        ],
      ]),
    );
  }
}

/// 我的 while signed out: one tap to the sign-in page.
class _SignInEntry extends StatelessWidget {
  const _SignInEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              const CircleAvatar(
                radius: 24,
                backgroundColor: AppColors.accentSoft,
                child: Icon(Icons.person_outline, color: AppColors.accent, size: 28),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('登录 / 注册',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.text)),
                  SizedBox(height: 4),
                  Text('同步宠物和养成数据，定制专属宠物',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                ]),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(20)),
                child: const Text('去登录', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ),
      );
}

/// 你的「豆豆」做好了 [换它陪我] [×] (generation spec 6.2).
class _ReadyBanner extends StatelessWidget {
  const _ReadyBanner({required this.pet, required this.onAdopt, required this.onDismiss});

  final ReadyPet pet;
  final VoidCallback onAdopt;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(_gutter, 16, _gutter, 0),
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(20)),
        child: Row(children: [
          const Icon(Icons.celebration, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text('你的「${pet.name}」做好了',
                style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.text)),
          ),
          FilledButton(onPressed: onAdopt, child: const Text('换它陪我')),
          IconButton(tooltip: '知道了', onPressed: onDismiss, icon: const Icon(Icons.close)),
        ]),
      );
}
