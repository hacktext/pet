import 'dart:convert';
import 'dart:io';

/// A real 1x1 transparent PNG, so Image.file has something decodable.
final kTinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

const kFiveActions = ['stand', 'walk', 'sleep', 'lick_paw', 'act_cute'];

/// Writes `<root>/<id>/` with pet.json, cover.png and one dummy mp4 per action.
/// complete: false leaves out the last clip (a half-downloaded folder).
Directory writePet(
  Directory root, {
  required String id,
  String species = 'dog',
  String origin = 'builtin',
  List<String> actions = kFiveActions,
  bool complete = true,
  String name = '测试宠物',
}) {
  final dir = Directory('${root.path}${Platform.pathSeparator}$id')..createSync(recursive: true);
  File('${dir.path}${Platform.pathSeparator}pet.json').writeAsStringSync(jsonEncode({
    'schema': 1,
    'id': id,
    'name': name,
    'species': species,
    'origin': origin,
    'blurb': '$name 的简介',
    'cover': 'cover.png',
    'actions': actions,
  }));
  File('${dir.path}${Platform.pathSeparator}cover.png').writeAsBytesSync(kTinyPng);
  final clips = complete ? actions : actions.sublist(0, actions.length - 1);
  for (final a in clips) {
    File('${dir.path}${Platform.pathSeparator}$a.mp4').writeAsBytesSync(utf8.encode('clip $id/$a'));
  }
  return dir;
}
