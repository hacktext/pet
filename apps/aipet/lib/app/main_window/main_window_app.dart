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
import 'main_window_model.dart';
import 'pet_card.dart';
import 'theme.dart';

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
            child: Column(children: [
              if (model.readyPet case final ready?)
                _ReadyBanner(pet: ready, onAdopt: model.adoptReady, onDismiss: model.dismissReady),
              Expanded(child: model.tab == 0 ? _PlazaPage(model: model) : _MinePage(model: model)),
            ]),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: model.tab,
            onDestinationSelected: model.setTab,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore), label: '宠物广场'),
              NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: '我的'),
            ],
          ),
        ),
      ),
    );
  }
}

class _PetGrid extends StatelessWidget {
  const _PetGrid({required this.model, required this.pets});

  final MainWindowModel model;
  final List<Pet> pets;

  @override
  Widget build(BuildContext context) => SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverGrid.count(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.68,
          children: [
            for (final p in pets) PetCard(pet: p, status: model.statusOf(p), onAdopt: () => model.adopt(p.id)),
          ],
        ),
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
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        sliver: SliverToBoxAdapter(
            child: _Banner(group: model.group, onCustom: () => openCustomFlow(context, model))),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        sliver: SliverToBoxAdapter(child: _GroupSwitch(model: model)),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, children: [
            for (final c in model.group.categories)
              ChoiceChip(
                label: Text(c.label),
                selected: model.category == c,
                selectedColor: AppColors.accentSoft,
                onSelected: (_) => model.setCategory(c),
              ),
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

/// 宠物 | 人物: one pill split in two, the chosen half filled in the accent.
class _GroupSwitch extends StatelessWidget {
  const _GroupSwitch({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(24)),
        child: Row(children: [
          for (final g in Group.values)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => model.setGroup(g),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: model.group == g ? AppColors.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    g.label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: model.group == g ? Colors.white : AppColors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.group, required this.onCustom});

  final Group group;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    final (title, subtitle) = switch (group) {
      Group.pets => ('定制专属宠物', '上传您的爱宠照片，生成桌面伙伴'),
      Group.people => ('定制专属角色', '上传照片，生成桌面角色'),
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(24)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.text)),
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          ]),
        ),
        FilledButton(onPressed: onCustom, child: const Text('立即定制')),
      ]),
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
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(child: _AccountCard(model: model)),
          ),
          if (model.account.signedIn && model.customs.isNotEmpty) _CustomList(model: model),
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
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton(onPressed: model.quit, child: const Text('退出程序')),
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
    return;
  }
  Navigator.of(context)
      .push(MaterialPageRoute<void>(
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
      .push(MaterialPageRoute<void>(
    builder: (_) => PlanPage(
      deps: deps,
      request: request,
      onAlreadyPaid: (ctx) =>
          Navigator.of(ctx).pushReplacement(MaterialPageRoute<void>(builder: (_) => submitted())),
      onOrder: (ctx, plan, order) => Navigator.of(ctx).push(MaterialPageRoute<void>(
        builder: (_) => PayPage(
          deps: deps,
          request: request,
          plan: plan,
          order: order,
          onPaid: (payCtx) => Navigator.of(payCtx).pushReplacement(MaterialPageRoute<void>(
            builder: (_) => submitted(),
          )),
        ),
      )),
    ),
  ))
      .then((_) => model.loadCustoms());
}

/// 我的定制: each order's first photo, name, category, plan and progress;
/// one still awaiting payment offers 去支付. A sliver, so up to 50 rows build
/// only as they scroll into view.
class _CustomList extends StatelessWidget {
  const _CustomList({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) {
    final rows = model.customs;
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
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
              trailing: r.status.awaitingPayment
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(r.statusText, style: const TextStyle(color: AppColors.textMuted)),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: () => openPlans(context, model, r), child: const Text('去支付')),
                    ])
                  : Text(r.statusText,
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

/// Sign in with a phone number and an SMS code, or -- signed in -- the
/// account, its last sync, 立即同步 and 退出登录 (web platform spec 8). The
/// pet window does the work; this only asks.
class _AccountCard extends StatefulWidget {
  const _AccountCard({required this.model});

  final MainWindowModel model;

  @override
  State<_AccountCard> createState() => _AccountCardState();
}

class _AccountCardState extends State<_AccountCard> {
  final _phone = TextEditingController();
  final _code = TextEditingController();

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _syncLine(AccountView a) {
    if (a.syncing) return '同步中…';
    final t = a.lastSyncAt;
    if (t == null) return '尚未同步';
    return '上次同步：${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final a = model.account;
    final error = model.accountError;
    final busy = model.accountBusy;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (a.signedIn) ...[
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
        ] else ...[
          const Text('登录后，宠物和养成数据可在多台电脑间同步',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
          const SizedBox(height: 8),
          TextField(
            key: const Key('account-phone'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(hintText: '手机号', isDense: true),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                key: const Key('account-code'),
                controller: _code,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: '验证码', isDense: true),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: busy || model.codeWait > 0 ? null : () => model.sendCode(_phone.text),
              child: Text(model.codeWait > 0 ? '${model.codeWait}秒后重发' : '获取验证码'),
            ),
          ]),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy ? null : () => model.login(_phone.text, _code.text),
            child: const Text('登录'),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
        ],
      ]),
    );
  }
}

/// 你的「豆豆」做好了 [换它陪我] [×] (generation spec 6.2).
class _ReadyBanner extends StatelessWidget {
  const _ReadyBanner({required this.pet, required this.onAdopt, required this.onDismiss});

  final ReadyPet pet;
  final VoidCallback onAdopt;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
