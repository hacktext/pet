import 'dart:io';

import 'package:aipet/app/pet_window/pet_sync_local.dart';
import 'package:aipet/app/pet_window/pet_window_controller.dart';
import 'package:aipet/app/pet_window/stats_keeper.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/domain/pet_stats.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:aipet/services/settings_store.dart';
import 'package:aipet/services/stats_store.dart';
import 'package:aipet/services/voice_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_player.dart';
import '../support/pet_fixtures.dart';

void main() {
  late Directory tmp, appData;
  late PetWindowController pets;
  late StatsKeeper stats;
  late VoiceStore voices;
  late PetSyncLocal local;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('synclocal_');
    final builtin = Directory('${tmp.path}\\builtin')..createSync();
    writePet(builtin, id: 'builtin-gold');
    writePet(builtin, id: 'builtin-ragdoll', species: 'cat');
    appData = Directory('${tmp.path}\\appdata');
    SettingsStore(appData).save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
    pets = PetWindowController(
      library: PetLibrary(builtinRoot: builtin, customRoot: Directory('${tmp.path}\\custom')),
      settings: SettingsStore(appData),
      ensure: (f) async => f,
      player: FakePlayer(),
      push: (_) async {},
    );
    stats = StatsKeeper(StatsStore(appData));
    voices = VoiceStore(appData);
    local = PetSyncLocal(pets: pets, stats: stats, voices: voices);
    await pets.boot();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('reads the three stores', () {
    stats.select('builtin-gold');
    voices.choose('builtin-gold', 'off');
    expect(local.settings, const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
    expect(local.stats.keys, ['builtin-gold']);
    expect(local.voices, {'builtin-gold': 'off'});
  });

  test('watchSettings: who is adopted or on the desktop changing counts; an action does not', () async {
    var changes = 0;
    local.watchSettings(() => changes++);
    await pets.playAction('sleep');
    expect(changes, 0);
    await pets.adopt('builtin-ragdoll');
    expect(changes, 1, reason: 'preparing alone is not a change; the switch is');
    await pets.adopt('builtin-gold');
    expect(changes, 2);
  });

  test('applies go to the stores', () async {
    await local.applySettings(const LibraryState(currentPetId: 'builtin-ragdoll', adoptedPetIds: ['builtin-ragdoll']));
    expect(pets.currentPet?.id, 'builtin-ragdoll');
    final s = PetStats.fresh(DateTime(2026, 10, 1));
    local.applyStats({'builtin-gold': s});
    expect(stats.all['builtin-gold'], s);
    local.applyVoices({'builtin-gold': 'vivi'});
    expect(voices.choice('builtin-gold'), 'vivi');
  });
}
