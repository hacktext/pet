import 'package:flutter/widgets.dart';
import 'alpha_video_controller.dart';

class AlphaVideoView extends StatelessWidget {
  const AlphaVideoView({super.key, required this.controller});

  final AlphaVideoController controller;

  @override
  Widget build(BuildContext context) => Texture(textureId: controller.textureId);
}
