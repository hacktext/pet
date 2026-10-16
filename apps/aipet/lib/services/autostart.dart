import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

/// 开机启动: on unless the user turned it off. The choice lives in
/// autostart.json (local, not synced); the system entry (the Run key on
/// Windows, a login item on macOS) is brought in line with it at every start,
/// so a reinstall to another folder points it at the new exe.
class Autostart {
  Autostart(this.root, {String? exe}) : _exe = exe ?? Platform.resolvedExecutable;

  final Directory root;
  final String _exe;

  /// The Run key's value name on Windows; the uninstaller removes it by name.
  static const appName = 'Aipet';

  File get file => File('${root.path}${Platform.pathSeparator}autostart.json');

  /// The user's choice; true when never made.
  bool get wanted {
    try {
      if (!file.existsSync()) return true;
      final j = jsonDecode(file.readAsStringSync());
      final v = j is Map<String, Object?> ? j['enabled'] : null;
      return v is bool ? v : true;
    } catch (_) {
      return true;
    }
  }

  void _remember(bool enabled) {
    try {
      root.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode({'enabled': enabled}), flush: true);
      tmp.renameSync(file.path);
    } catch (e) {
      developer.log('saving autostart.json failed: $e', name: 'aipet.autostart');
    }
  }

  /// At startup: the system entry made to match the choice. Never throws.
  Future<void> apply() => _set(wanted);

  /// From the tray menu.
  Future<void> choose(bool enabled) async {
    _remember(enabled);
    await _set(enabled);
  }

  Future<void> _set(bool enabled) async {
    try {
      // Quoted: a user name with a space must not split the Run key's command.
      launchAtStartup.setup(appName: appName, appPath: Platform.isWindows ? '"$_exe"' : _exe);
      enabled ? await launchAtStartup.enable() : await launchAtStartup.disable();
    } catch (e) {
      // macOS needs the runner's launch_at_startup channel; without it, or
      // without registry access, the pet still runs, just not at login.
      developer.log('autostart ${enabled ? 'on' : 'off'} failed: $e', name: 'aipet.autostart');
    }
  }
}
