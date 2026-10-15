import 'dart:io';

final String _sep = Platform.pathSeparator;

/// %APPDATA%\com.aipet\aipet on Windows (parent spec 4.4);
/// ~/Library/Application Support/com.aipet/aipet on macOS. [macOS] is for
/// tests; it defaults to the platform this runs on.
Directory appDataRoot([Map<String, String>? env, bool? macOS]) {
  final e = env ?? Platform.environment;
  if (macOS ?? Platform.isMacOS) {
    final home = e['HOME'];
    if (home == null || home.isEmpty) throw StateError('HOME is not set');
    return Directory('$home/Library/Application Support/com.aipet/aipet');
  }
  final base = e['APPDATA'];
  if (base == null || base.isEmpty) throw StateError('APPDATA is not set');
  return Directory('$base${_sep}com.aipet${_sep}aipet');
}

Directory customPetsRoot(Directory appData) => Directory('${appData.path}${_sep}pets');

Directory matteCacheRoot(Directory appData) => Directory('${appData.path}${_sep}matte-cache${_sep}v1');

/// Flutter assets are plain files, so pet_matte can decode the built-in
/// clips in place by path: next to the exe on Windows; inside the bundle on
/// macOS (aipet.app/Contents/MacOS/aipet ->
/// aipet.app/Contents/Frameworks/App.framework/Resources/flutter_assets).
Directory builtinPetsRoot([String? executable, bool? macOS]) {
  final exeDir = File(executable ?? Platform.resolvedExecutable).parent.path;
  if (macOS ?? Platform.isMacOS) {
    final contents = exeDir.substring(0, exeDir.lastIndexOf('/'));
    return Directory('$contents/Frameworks/App.framework/Resources/flutter_assets/assets/pets');
  }
  return Directory('$exeDir${_sep}data${_sep}flutter_assets${_sep}assets${_sep}pets');
}
