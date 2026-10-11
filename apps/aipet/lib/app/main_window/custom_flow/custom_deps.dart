import 'package:file_selector/file_selector.dart';

import '../../../services/custom_service.dart';
import '../../../services/oss_uploader.dart';
import '../../../services/photo_prep.dart';

/// A file the user picked: its name (for messages) and its bytes.
class PickedFile {
  const PickedFile(this.name, this.bytes);

  final String name;
  final List<int> bytes;
}

/// What the custom-pet pages need from outside; tests pass fakes.
class CustomDeps {
  CustomDeps({
    required this.service,
    required this.uploader,
    required this.pick,
    Future<List<int>> Function(List<int>)? prep,
  }) : prep = prep ?? prepPhotoInBackground;

  final CustomService service;
  final OssUploader uploader;
  final Future<List<PickedFile>> Function() pick;
  final Future<List<int>> Function(List<int>) prep;
}

/// The real picker: up to a few JPG/PNG files from disk via the system dialog.
Future<List<PickedFile>> pickPhotosFromDisk() async {
  final files = await openFiles(acceptedTypeGroups: const [
    XTypeGroup(label: '图片', extensions: ['jpg', 'jpeg', 'png']),
  ]);
  return [for (final f in files) PickedFile(f.name, await f.readAsBytes())];
}
