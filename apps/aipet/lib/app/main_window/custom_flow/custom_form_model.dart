import 'package:flutter/foundation.dart' hide Category;

import '../../../domain/custom_order.dart';
import '../../../domain/library_state.dart';
import '../../../services/custom_service.dart';
import '../../../services/oss_uploader.dart';
import 'custom_deps.dart';

const kMaxPhotos = 3;
const kNameMax = 8;

/// One chosen photo, already shrunk to the JPEG that gets uploaded; [key] once
/// OSS has it, so a retry sends only what is still missing.
class FormPhoto {
  FormPhoto(this.name, this.jpeg);

  final String name;
  final List<int> jpeg;
  String? key;
  bool failed = false;
}

/// 定制页 (custom order spec 3, step 2).
class CustomFormModel extends ChangeNotifier {
  CustomFormModel(this._deps);

  final CustomDeps _deps;

  String _name = '';
  String? _serverNameError;
  String? _categoryError;
  Category _category = Category.cat;
  final List<FormPhoto> _photos = [];
  bool _busy = false;
  String? _progress;
  String? _message;

  String get name => _name;
  int get nameLength => _name.trim().runes.length;
  String? get nameError => nameLength > kNameMax ? '名字最多 $kNameMax 个字' : _serverNameError;

  /// The server's refusal of the chosen category (5010 on species), if any.
  String? get categoryError => _categoryError;
  Group get group => _category.group;
  Category get category => _category;
  List<FormPhoto> get photos => List.unmodifiable(_photos);
  bool get busy => _busy;

  /// 正在上传 2/3 while uploading.
  String? get progress => _progress;

  /// The last thing to tell the user; null when there is nothing.
  String? get message => _message;

  bool get canSubmit => !_busy && nameLength >= 1 && nameLength <= kNameMax && _photos.isNotEmpty;

  void setName(String v) {
    _name = v;
    _serverNameError = null;
    notifyListeners();
  }

  void setGroup(Group g) {
    if (g == group) return;
    _category = g.categories.firstWhere((c) => c.species != null);
    _categoryError = null;
    notifyListeners();
  }

  void setCategory(Category c) {
    if (c.species == null) return;
    _category = c;
    _categoryError = null;
    notifyListeners();
  }

  Future<void> addPhotos() async {
    if (_busy) return;
    _message = null;
    final room = kMaxPhotos - _photos.length;
    if (room <= 0) {
      _message = '最多 $kMaxPhotos 张照片';
      notifyListeners();
      return;
    }
    final picked = await _deps.pick();
    if (picked.length > room) _message = '最多 $kMaxPhotos 张照片';
    for (final f in picked.take(room)) {
      try {
        _photos.add(FormPhoto(f.name, await _deps.prep(f.bytes)));
      } catch (_) {
        // PhotoPrepError, or anything else that kept the file from becoming a JPEG.
        _message = '无法读取图片：${f.name}';
      }
    }
    notifyListeners();
  }

  void removePhoto(int i) {
    if (_busy || i < 0 || i >= _photos.length) return;
    _photos.removeAt(i);
    notifyListeners();
  }

  /// Uploads what is not up yet, then creates the request; null (with
  /// [message], [nameError] or [categoryError] set) when something went wrong.
  Future<CustomRequestInfo?> submit() async {
    if (!canSubmit) return null;
    _busy = true;
    _message = null;
    _serverNameError = null;
    _categoryError = null;
    notifyListeners();
    try {
      final missing = [for (final p in _photos) if (p.key == null) p];
      if (missing.isNotEmpty) {
        final tickets = await _deps.service.tickets(missing.length);
        for (var i = 0; i < missing.length; i++) {
          final p = missing[i];
          final n = _photos.indexOf(p) + 1;
          _progress = '正在上传 $n/${_photos.length}';
          notifyListeners();
          try {
            await _deps.uploader.upload(tickets[i], p.jpeg);
            p
              ..key = tickets[i].key
              ..failed = false;
          } on OssUploadFailed {
            p.failed = true;
            _message = '第 $n 张上传失败，请重试';
            return null;
          }
        }
      }
      _progress = '正在提交…';
      notifyListeners();
      return await _deps.service.create(
        name: _name.trim(),
        species: _category.species!.name,
        photoKeys: [for (final p in _photos) p.key!],
      );
    } on CustomFailure catch (f) {
      switch (f.field) {
        case 'name':
          _serverNameError = f.message;
        case 'species':
          _categoryError = f.message;
        default:
          // A stale or rejected photo key: upload them again next time.
          if (f.field == 'photo_keys') {
            for (final p in _photos) {
              p.key = null;
            }
          }
          _message = f.message;
      }
      return null;
    } finally {
      _busy = false;
      _progress = null;
      notifyListeners();
    }
  }
}
