import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

const MethodChannel kEditChannel = MethodChannel('camera_dokumentasi/media_store');

/// Minta Galeri Android memperbarui daftarnya.
Future<void> scanMediaPaths(List<String> paths) async {
  if (!Platform.isAndroid || paths.isEmpty) return;
  try {
    await kEditChannel.invokeMethod('scanFiles', <String, dynamic>{'paths': paths});
  } catch (_) {}
}

String sanitizeName(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();

/// Dialog nama file. Mengembalikan nama tanpa ekstensi, atau null bila dibatalkan.
class RenameDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String suffix;
  final String okLabel;
  const RenameDialog({super.key, required this.title, required this.initial, required this.suffix, this.okLabel = 'SIMPAN'});
  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    _c.selection = TextSelection(baseOffset: 0, extentOffset: _c.text.length);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() {
    final n = sanitizeName(_c.text);
    Navigator.pop(context, n.isEmpty ? widget.initial : n);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(labelText: 'Nama file', suffixText: widget.suffix, border: const OutlineInputBorder()),
        onSubmitted: (_) => _ok(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('BATAL')),
        FilledButton(onPressed: _ok, child: Text(widget.okLabel)),
      ],
    );
  }
}

// ───────────────────────── Overlay (teks / stiker / watermark) ─────────────────────────

class OverlayItem {
  OverlayItem({
    required this.kind,
    this.text = '',
    this.image,
    this.pos = const Offset(.5, .5),
    this.size = .1,
    this.color = Colors.white,
    this.opacity = 1,
    this.rotation = 0,
    this.bold = true,
  });

  /// 'text' | 'sticker' | 'watermark' | 'logo'
  String kind;
  String text;
  ui.Image? image;
  Offset pos; // pusat, relatif 0..1 terhadap frame
  double size; // relatif terhadap sisi terpendek frame
  Color color;
  double opacity;
  double rotation; // derajat
  bool bold;
}

TextPainter _painterFor(OverlayItem it, double shortSide) {
  final fs = math.max(6.0, shortSide * it.size);
  final sticker = it.kind == 'sticker';
  return TextPainter(
    text: TextSpan(
      text: it.text,
      style: TextStyle(
        fontSize: fs,
        color: sticker ? Colors.white : it.color.withValues(alpha: it.opacity),
        fontWeight: it.bold ? FontWeight.w800 : FontWeight.w500,
        shadows: sticker ? null : [Shadow(blurRadius: fs * .08, color: Colors.black.withValues(alpha: .7 * it.opacity), offset: Offset(fs * .03, fs * .03))],
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
  )..layout();
}

Size _sizeOf(OverlayItem it, double shortSide) {
  final im = it.image;
  if (im != null) {
    final w = shortSide * it.size;
    return Size(w, w * im.height / im.width);
  }
  return _painterFor(it, shortSide).size;
}

void paintOverlays(Canvas canvas, Size size, List<OverlayItem> items, {int selected = -1}) {
  final s = size.shortestSide;
  for (var i = 0; i < items.length; i++) {
    final it = items[i];
    final sz = _sizeOf(it, s);
    canvas.save();
    canvas.translate(it.pos.dx * size.width, it.pos.dy * size.height);
    canvas.rotate(it.rotation * math.pi / 180);
    final im = it.image;
    if (im != null) {
      final paint = Paint()
        ..color = Color.fromRGBO(255, 255, 255, it.opacity.clamp(0.0, 1.0).toDouble())
        ..filterQuality = FilterQuality.high;
      canvas.drawImageRect(
        im,
        Rect.fromLTWH(0, 0, im.width.toDouble(), im.height.toDouble()),
        Rect.fromCenter(center: Offset.zero, width: sz.width, height: sz.height),
        paint,
      );
    } else {
      final tp = _painterFor(it, s);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    }
    if (i == selected) {
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: sz.width, height: sz.height).inflate(6),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.lightBlueAccent,
      );
    }
    canvas.restore();
  }
}

class _OverlayPainter extends CustomPainter {
  final List<OverlayItem> items;
  final int selected;
  _OverlayPainter(this.items, this.selected);
  @override
  void paint(Canvas canvas, Size size) => paintOverlays(canvas, size, items, selected: selected);
  @override
  bool shouldRepaint(covariant _OverlayPainter old) => true;
}

/// Lapisan di atas preview: geser untuk memindah, cubit untuk memperbesar/memutar.
class OverlayCanvas extends StatefulWidget {
  final List<OverlayItem> items;
  final int selected;
  final bool interactive;
  final ValueChanged<int> onSelect;
  final VoidCallback onChanged;
  const OverlayCanvas({super.key, required this.items, required this.selected, required this.onSelect, required this.onChanged, this.interactive = true});
  @override
  State<OverlayCanvas> createState() => _OverlayCanvasState();
}

class _OverlayCanvasState extends State<OverlayCanvas> {
  Size _size = Size.zero;
  int _active = -1;
  Offset _startPos = Offset.zero;
  double _startSize = .1;
  double _startRot = 0;
  Offset _startFocal = Offset.zero;

  int _hit(Offset p) {
    final s = _size.shortestSide;
    for (var i = widget.items.length - 1; i >= 0; i--) {
      final it = widget.items[i];
      final sz = _sizeOf(it, s);
      final c = Offset(it.pos.dx * _size.width, it.pos.dy * _size.height);
      final d = p - c;
      final a = -it.rotation * math.pi / 180;
      final lx = d.dx * math.cos(a) - d.dy * math.sin(a);
      final ly = d.dx * math.sin(a) + d.dy * math.cos(a);
      if (lx.abs() <= sz.width / 2 + 14 && ly.abs() <= sz.height / 2 + 14) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        _size = c.biggest;
        final paint = CustomPaint(size: c.biggest, painter: _OverlayPainter(widget.items, widget.interactive ? widget.selected : -1));
        if (!widget.interactive) return IgnorePointer(child: paint);
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onScaleStart: (d) {
            final hit = _hit(d.localFocalPoint);
            _active = hit;
            if (hit >= 0) {
              widget.onSelect(hit);
              final it = widget.items[hit];
              _startPos = it.pos;
              _startSize = it.size;
              _startRot = it.rotation;
              _startFocal = d.localFocalPoint;
            }
          },
          onScaleUpdate: (d) {
            if (_active < 0 || _active >= widget.items.length || _size.isEmpty) return;
            final it = widget.items[_active];
            final delta = d.localFocalPoint - _startFocal;
            it.pos = Offset(
              (_startPos.dx + delta.dx / _size.width).clamp(0.0, 1.0).toDouble(),
              (_startPos.dy + delta.dy / _size.height).clamp(0.0, 1.0).toDouble(),
            );
            if (d.pointerCount >= 2) {
              it.size = (_startSize * d.scale).clamp(.02, 1.2).toDouble();
              it.rotation = _startRot + d.rotation * 180 / math.pi;
            }
            widget.onChanged();
          },
          child: paint,
        );
      },
    );
  }
}

Future<Uint8List> renderOverlayPng(List<OverlayItem> items, int w, int h) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  paintOverlays(canvas, Size(w.toDouble(), h.toDouble()), items);
  final pic = rec.endRecording();
  final image = await pic.toImage(w, h);
  final bd = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  pic.dispose();
  if (bd == null) throw Exception('Gagal membuat lapisan teks/stiker');
  return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
}

Uint8List _encodeRgbaJob(Map<String, dynamic> a) {
  final data = Uint8List.fromList(a['rgba'] as Uint8List);
  final im = img.Image.fromBytes(width: a['w'] as int, height: a['h'] as int, bytes: data.buffer, numChannels: 4);
  return Uint8List.fromList(img.encodeJpg(im, quality: a['q'] as int));
}

/// Menempelkan teks/stiker/watermark ke foto JPEG beresolusi penuh.
Future<Uint8List> burnOverlaysOnJpeg(Uint8List jpg, List<OverlayItem> items) async {
  final codec = await ui.instantiateImageCodec(jpg);
  final frame = await codec.getNextFrame();
  final base = frame.image;
  final w = base.width;
  final h = base.height;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
  canvas.drawImage(base, Offset.zero, Paint());
  paintOverlays(canvas, Size(w.toDouble(), h.toDouble()), items);
  final pic = rec.endRecording();
  final out = await pic.toImage(w, h);
  final bd = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
  base.dispose();
  out.dispose();
  pic.dispose();
  codec.dispose();
  if (bd == null) throw Exception('Gagal menempelkan teks/stiker');
  return compute(_encodeRgbaJob, <String, dynamic>{
    'rgba': bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes),
    'w': w,
    'h': h,
    'q': 95,
  });
}

Future<ui.Image?> loadUiImage(String path, {int maxWidth = 640}) async {
  try {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: maxWidth);
    return (await codec.getNextFrame()).image;
  } catch (_) {
    return null;
  }
}

const List<String> kStickers = [
  '⚠️', '❌', '✅', '❗', '❓', '🔴', '🟡', '🟢', '⭐', '👍', '👎', '💥',
  '🚫', '🔍', '🔧', '🛠️', '📦', '📌', '📷', '⏱️', '➡️', '⬅️', '⬆️', '⬇️',
  '1️⃣', '2️⃣', '3️⃣', '4️⃣', '5️⃣', '🧱', '💧', '🔥',
];

const List<Color> kOverlayColors = [Colors.white, Colors.yellow, Colors.redAccent, Colors.black, Colors.cyanAccent, Colors.lightGreenAccent];

/// Panel alat untuk teks / stiker / watermark (dipakai editor foto & video).
class OverlayPanel extends StatelessWidget {
  final String mode; // 'text' | 'sticker' | 'watermark'
  final List<OverlayItem> items;
  final int selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onChanged;
  const OverlayPanel({super.key, required this.mode, required this.items, required this.selected, required this.onSelect, required this.onChanged});

  void _add(OverlayItem it) {
    items.add(it);
    onSelect(items.length - 1);
    onChanged();
  }

  Future<String?> _askText(BuildContext context, String title, String hint, {String initial = ''}) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _TextDialog(title: title, hint: hint, initial: initial),
    );
  }

  String _stamp() {
    final n = DateTime.now();
    String t(int v) => v.toString().padLeft(2, '0');
    return '${t(n.day)}/${t(n.month)}/${n.year} ${t(n.hour)}:${t(n.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final sel = (selected >= 0 && selected < items.length) ? items[selected] : null;
    final children = <Widget>[];
    switch (mode) {
      case 'text':
        children.add(
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () async {
                  final t = await _askText(context, 'Tambahkan teks', 'Contoh: RETAK / PECAH / PENYOK');
                  if (t == null || t.isEmpty) return;
                  _add(OverlayItem(kind: 'text', text: t, size: .08, color: Colors.white));
                },
                icon: const Icon(Icons.title),
                label: const Text('TAMBAH TEKS'),
              ),
            ),
            if (sel != null && sel.kind == 'text') ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final t = await _askText(context, 'Ubah teks', '', initial: sel.text);
                  if (t == null || t.isEmpty) return;
                  sel.text = t;
                  onChanged();
                },
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('UBAH'),
              ),
            ],
          ]),
        );
        break;
      case 'sticker':
        children.add(
          SizedBox(
            height: 50,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final e in kStickers)
                  InkWell(
                    onTap: () => _add(OverlayItem(kind: 'sticker', text: e, size: .16)),
                    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Center(child: Text(e, style: const TextStyle(fontSize: 30)))),
                  ),
              ],
            ),
          ),
        );
        break;
      default:
        children.add(
          Wrap(spacing: 8, runSpacing: 6, children: [
            OutlinedButton.icon(
              onPressed: () async {
                final t = await _askText(context, 'Teks watermark', 'Contoh: Camera Dokumentasi', initial: 'Camera Dokumentasi');
                if (t == null || t.isEmpty) return;
                _add(OverlayItem(kind: 'watermark', text: t, size: .05, opacity: .65, pos: const Offset(.72, .94), bold: false));
              },
              icon: const Icon(Icons.branding_watermark, size: 18),
              label: const Text('TEKS'),
            ),
            OutlinedButton.icon(
              onPressed: () => _add(OverlayItem(kind: 'watermark', text: _stamp(), size: .045, opacity: .8, pos: const Offset(.72, .94), color: Colors.yellow)),
              icon: const Icon(Icons.schedule, size: 18),
              label: const Text('TANGGAL & JAM'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final res = await FilePicker.platform.pickFiles(type: FileType.image);
                final path = res?.files.single.path;
                if (path == null) return;
                final im = await loadUiImage(path);
                if (im == null) return;
                _add(OverlayItem(kind: 'logo', image: im, size: .2, opacity: .7, pos: const Offset(.8, .88)));
              },
              icon: const Icon(Icons.image_outlined, size: 18),
              label: const Text('LOGO'),
            ),
          ]),
        );
    }
    if (sel != null) {
      children.add(const SizedBox(height: 4));
      children.add(
        Row(children: [
          const SizedBox(width: 58, child: Text('Ukuran', style: TextStyle(color: Colors.white70, fontSize: 12))),
          Expanded(
            child: Slider(
              value: sel.size.clamp(.02, .8).toDouble(),
              min: .02,
              max: .8,
              onChanged: (v) {
                sel.size = v;
                onChanged();
              },
            ),
          ),
          IconButton(
            tooltip: 'Hapus',
            onPressed: () {
              items.removeAt(selected);
              onSelect(-1);
              onChanged();
            },
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          ),
        ]),
      );
      if (sel.kind != 'sticker') {
        children.add(
          Row(children: [
            const SizedBox(width: 58, child: Text('Transp.', style: TextStyle(color: Colors.white70, fontSize: 12))),
            Expanded(
              child: Slider(
                value: sel.opacity.clamp(.1, 1.0).toDouble(),
                min: .1,
                max: 1,
                onChanged: (v) {
                  sel.opacity = v;
                  onChanged();
                },
              ),
            ),
            if (sel.image == null)
              for (final c in kOverlayColors.take(4))
                GestureDetector(
                  onTap: () {
                    sel.color = c;
                    onChanged();
                  },
                  child: Container(
                    width: 22,
                    height: 22,
                    margin: const EdgeInsets.only(left: 6),
                    decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: sel.color == c ? Colors.lightBlueAccent : Colors.white38, width: 2)),
                  ),
                ),
          ]),
        );
      }
    } else if (items.isNotEmpty) {
      children.add(const Padding(padding: EdgeInsets.only(top: 4), child: Text('Ketuk item pada gambar untuk memilih. Geser = pindah, cubit = ukuran & putar.', style: TextStyle(color: Colors.white54, fontSize: 11))));
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

class _TextDialog extends StatefulWidget {
  final String title;
  final String hint;
  final String initial;
  const _TextDialog({required this.title, required this.hint, required this.initial});
  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(controller: _c, autofocus: true, keyboardType: TextInputType.text, decoration: InputDecoration(hintText: widget.hint)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('BATAL')),
        FilledButton(onPressed: () => Navigator.pop(context, _c.text.trim()), child: const Text('OK')),
      ],
    );
  }
}
