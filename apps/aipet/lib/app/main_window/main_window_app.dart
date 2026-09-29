import 'package:flutter/material.dart';

import '../../domain/library_state.dart';
import '../../domain/pet.dart';
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
      home: ListenableBuilder(
        listenable: model,
        builder: (context, _) => Scaffold(
          body: SafeArea(child: model.tab == 0 ? _PlazaPage(model: model) : _MinePage(model: model)),
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
      const SliverPadding(padding: EdgeInsets.fromLTRB(16, 16, 16, 8), sliver: SliverToBoxAdapter(child: _Banner())),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, children: [
            for (final c in Category.values)
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

class _Banner extends StatelessWidget {
  const _Banner();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(24)),
        child: Row(children: [
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('定制专属宠物', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.text)),
              SizedBox(height: 4),
              Text('上传您的爱宠照片，生成桌面伙伴', style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
            ]),
          ),
          FilledButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                content: const Text('即将开放，敬请期待'),
                actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('知道了'))],
              ),
            ),
            child: const Text('立即定制'),
          ),
        ]),
      );
}

class _MinePage extends StatelessWidget {
  const _MinePage({required this.model});

  final MainWindowModel model;

  @override
  Widget build(BuildContext context) {
    final pets = model.minePets;
    return Column(children: [
      Expanded(
        child: pets.isEmpty
            ? const Center(child: Text('还没有领养小伙伴，去广场看看吧', style: TextStyle(color: AppColors.textMuted)))
            : CustomScrollView(slivers: [_PetGrid(model: model, pets: pets)]),
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
