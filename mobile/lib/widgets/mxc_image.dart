import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'avatar.dart';

/// Картинка с сервера (mxc://) — миниатюра нужного размера.
class MxcImage extends StatelessWidget {
  final Uri mxc;
  final int size;
  final BoxFit fit;
  const MxcImage({super.key, required this.mxc, this.size = 256, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: loadThumb(mxc, size, method: 'scale'),
        builder: (_, s) => s.data == null ? const SizedBox.shrink() : Image.memory(s.data!, fit: fit, gaplessPlayback: true, cacheWidth: size * 2, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
      );
}
