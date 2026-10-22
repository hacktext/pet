import 'dart:developer' as developer;
import 'dart:io';

/// Written next to aipet.exe by the Windows installer on a fresh install (not
/// an upgrade): the first launch shows the library and keeps the pet off the
/// desktop until the user picks one or closes the library, even when
/// %APPDATA% kept a pet from an earlier install or the account syncs one in.
const kFirstRunMark = 'first-run';

/// Whether [dir] holds the mark; it is deleted, so only this launch sees it.
/// Never throws: a mark that cannot be read or deleted counts as there and
/// gone (worst case the library opens once more).
bool takeFirstRunMark(Directory dir) {
  final f = File('${dir.path}${Platform.pathSeparator}$kFirstRunMark');
  try {
    if (!f.existsSync()) return false;
  } catch (_) {
    return false;
  }
  try {
    f.deleteSync();
  } catch (e) {
    developer.log('could not delete the first-run mark: $e', name: 'aipet.first_run');
  }
  return true;
}
