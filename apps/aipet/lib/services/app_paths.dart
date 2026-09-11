import 'dart:io';

final String _sep = Platform.pathSeparator;

/// %APPDATA%\com.aipet\aipet (parent spec 4.4).
Directory appDataRoot([Map<String, String>? env]) {
  final base = (env ?? Platform.environment)['APPDATA'];
  if (base == null || base.isEmpty) throw StateError('APPDATA is not set');
  return Directory('$base${_sep}com.aipet${_sep}aipet');
}

Directory customPetsRoot(Directory appData) => Directory('${appData.path}${_sep}pets');

Directory matteCacheRoot(Directory appData) => Directory('${appData.path}${_sep}matte-cache${_sep}v1');

/// Flutter assets are plain files on Windows, so pet_matte can decode the
/// built-in clips in place by path.
Directory builtinPetsRoot([String? executable]) => Directory(
    '${File(executable ?? Platform.resolvedExecutable).parent.path}${_sep}data${_sep}flutter_assets${_sep}assets${_sep}pets');
