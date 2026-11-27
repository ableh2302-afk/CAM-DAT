import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'editor_common.dart';

enum _VTool { trim, crop, rotate, effect, text, sticker, watermark }

class _VFilter {
  final String id;
  final String label;
  final List<double> matrix;
  const _VFilter(this.id, this.label, this.matrix);
}

const List<double> _identity = [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];

const List<_VFilter> _filters = [
  _VFilter('normal', 'Normal', _identity),
  _VFilter('mono', 'Hitam-Putih', [.299, .587, .114, 0, 0, .299, .587, .114, 0, 0, .299, .587, .114, 0, 0, 0, 0, 0, 1, 0]),
  _VFilter('sepia', 'Sepia', [.393, .769, .189, 0, 0, .349, .686, .168, 0, 0, .272, .534, .131, 0, 0, 0, 0, 0, 1, 0]),
  _VFilter('invert', 'Negatif', [-1, 0, 0, 0, 255, 0, -1, 0, 0, 255, 0, 0, -1, 0, 255, 0, 0, 0, 1, 0]),
  _VFilter('warm', 'Hangat', [1.12, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, .88, 0, 0, 0, 0, 0, 1, 0]),
  _VFilter('cool', 'Dingin', [.88, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1.12, 0, 0, 0, 0, 0, 1, 0]),
  _VFilter('bright', 'Terang', [1, 0, 0, 0, 30, 0, 1, 0, 0, 30, 0, 0, 1, 0, 30, 0, 0, 0, 1, 0]),
  _VFilter('contrast', 'Kontras', [1.25, 0, 0, 0, -32, 0, 1.25, 0, 0, -32, 0, 0, 1.25, 0, -32, 0, 0, 0, 1, 0]),
];

class VideoEditorPage extends StatefulWidget {
  final File file;
  const VideoEditorPage({super.key, required this.file});
  @override
  State<VideoEditorPage> createState() => _VideoEditorPageState();
}

class _VideoEditorPageState extends State<VideoEditorPage> {
  late final VideoPlayerController _vc;
  bool _ready = false;
  String? _error;
  double _durMs = 1;
  RangeValues _range = const RangeValues(0, 1);

  _VTool _tool = _VTool.trim;
  int _quarter = 0; // putaran searah jarum jam (x90°)
  bool _flip = false;
  Rect _crop = const Rect.fromLTRB(0, 0, 1, 1);
  double? _cropAspect; // null = bebas
  _VFilter _filter = _filters.first;
  bool _mute = false;
  final List<OverlayItem> _items = [];
  int _sel = -1;

  bool _saving = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _vc = VideoPlayerController.file(widget.file);
    _vc.addListener(_tick);
    _vc.initialize().then((_) {
      if (!mounted) return;
      _durMs = math.max(1, _vc.value.duration.inMilliseconds.toDouble());
      setState(() {
        _ready = true;
        _range = RangeValues(0, _durMs);
      });
    }).catchError((e) {
      if (mounted) setState(() => _error = 'Video tidak dapat dibuka.');
    });
  }

  @override
  void dispose() {
    _vc.removeListener(_tick);
    _vc.dispose();
    super.dispose();
  }

  void _tick() {
    if (!mounted || !_ready) return;
    final pos = _vc.value.position.inMilliseconds;
    if (_vc.value.isPlaying && pos >= _range.end - 40) {
      _vc.pause();
      _vc.seekTo(Duration(milliseconds: _range.start.round()));
    }
    setState(() {});
  }

  // ───────────── Geometri ─────────────

  bool get _odd => _quarter.isOdd;
  Size get _src => _vc.value.size;
  double get _rw => _odd ? _src.height : _src.width; // lebar frame setelah diputar
  double get _rh => _odd ? _src.width : _src.height;

  String _fmt(double ms) {
    final s = (ms / 1000);
    final m = s ~/ 60;
    final r = s - m * 60;
    return '${m.toString().padLeft(2, '0')}:${r.toStringAsFixed(1).padLeft(4, '0')}';
  }

  Future<void> _togglePlay() async {
    if (_vc.value.isPlaying) {
      await _vc.pause();
      return;
    }
    final pos = _vc.value.position.inMilliseconds;
    if (pos < _range.start || pos >= _range.end - 60) {
      await _vc.seekTo(Duration(milliseconds: _range.start.round()));
    }
    await _vc.play();
  }

  void _setCropAspect(double? a) {
    _cropAspect = a;
    if (a == null) {
      setState(() => _crop = const Rect.fromLTRB(0, 0, 1, 1));
      return;
    }
    final frameAspect = _rw / _rh;
    double fw;
    double fh;
    if (frameAspect > a) {
      fh = 1;
      fw = a / frameAspect;
    } else {
      fw = 1;
      fh = frameAspect / a;
    }
    setState(() => _crop = Rect.fromLTWH((1 - fw) / 2, (1 - fh) / 2, fw, fh));
  }

  void _rotate(int dq) {
    setState(() {
      _quarter = (_quarter + dq) % 4;
      if (_quarter < 0) _quarter += 4;
      _crop = const Rect.fromLTRB(0, 0, 1, 1);
      _cropAspect = null;
    });
  }

  // ───────────── Preview ─────────────

  Widget _preview() {
    final cropTool = _tool == _VTool.crop;
    final rect = cropTool ? const Rect.fromLTRB(0, 0, 1, 1) : _crop;
    final aspect = (_rw * rect.width) / (_rh * rect.height);
    final overlayTool = _tool == _VTool.text || _tool == _VTool.sticker || _tool == _VTool.watermark;
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: LayoutBuilder(
          builder: (ctx, c) {
            final fullW = c.maxWidth / rect.width;
            final fullH = c.maxHeight / rect.height;
            return ClipRect(
              child: Stack(
                children: [
                  Positioned(
                    left: -rect.left * fullW,
                    top: -rect.top * fullH,
                    width: fullW,
                    height: fullH,
                    child: ColorFiltered(
                      colorFilter: ColorFilter.matrix(_filter.matrix),
                      child: Transform.flip(
                        flipX: _flip,
                        child: RotatedBox(quarterTurns: _quarter, child: VideoPlayer(_vc)),
                      ),
                    ),
                  ),
                  if (cropTool)
                    Positioned.fill(
                      child: CropBox(
                        rect: _crop,
                        aspect: _cropAspect,
                        frame: Size(_rw, _rh),
                        onChanged: (r) => setState(() => _crop = r),
                      ),
                    )
                  else
                    Positioned.fill(
                      child: OverlayCanvas(
                        items: _items,
                        selected: _sel,
                        interactive: overlayTool,
                        onSelect: (i) => setState(() => _sel = i),
                        onChanged: () => setState(() {}),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // ───────────── Panel alat ─────────────

  Widget _panel() {
    switch (_tool) {
      case _VTool.trim:
        final start = _range.start;
        final end = _range.end;
        return Column(mainAxisSize: MainAxisSize.min, children: [
          RangeSlider(
            values: _range,
            min: 0,
            max: _durMs,
            onChanged: (v) {
              var r = v;
              if (r.end - r.start < 500) {
                r = (v.start != _range.start) ? RangeValues(math.max(0, r.end - 500), r.end) : RangeValues(r.start, math.min(_durMs, r.start + 500));
              }
              final moved = r.start != _range.start ? r.start : r.end;
              setState(() => _range = r);
              _vc.seekTo(Duration(milliseconds: moved.round()));
            },
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Mulai ${_fmt(start)}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
            Text('Durasi ${_fmt(end - start)}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
            Text('Akhir ${_fmt(end)}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ]),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Hilangkan suara', style: TextStyle(color: Colors.white)),
            value: _mute,
            onChanged: (v) => setState(() {
              _mute = v;
              _vc.setVolume(v ? 0 : 1);
            }),
          ),
        ]);
      case _VTool.crop:
        final presets = <(String, double?)>[('Bebas', null), ('1:1', 1.0), ('4:3', 4 / 3), ('3:4', 3 / 4), ('16:9', 16 / 9), ('9:16', 9 / 16)];
        return Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final p in presets)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(label: Text(p.$1), selected: _cropAspect == p.$2, onSelected: (_) => _setCropAspect(p.$2)),
                  ),
              ],
            ),
          ),
          const Text('Geser sudut kotak untuk mengubah ukuran, geser isi kotak untuk memindah.', style: TextStyle(color: Colors.white54, fontSize: 11)),
        ]);
      case _VTool.rotate:
        return Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(onPressed: () => _rotate(1), icon: const Icon(Icons.rotate_right), label: const Text('KANAN 90°')),
          FilledButton.icon(onPressed: () => _rotate(-1), icon: const Icon(Icons.rotate_left), label: const Text('KIRI 90°')),
          OutlinedButton.icon(onPressed: () => setState(() => _flip = !_flip), icon: const Icon(Icons.flip), label: Text(_flip ? 'CERMIN: AKTIF' : 'CERMIN')),
        ]);
      case _VTool.effect:
        return SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final f in _filters)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(label: Text(f.label), selected: _filter.id == f.id, onSelected: (_) => setState(() => _filter = f)),
                ),
            ],
          ),
        );
      case _VTool.text:
      case _VTool.sticker:
      case _VTool.watermark:
        return OverlayPanel(
          mode: _tool == _VTool.text ? 'text' : (_tool == _VTool.sticker ? 'sticker' : 'watermark'),
          items: _items,
          selected: _sel,
          onSelect: (i) => setState(() => _sel = i),
          onChanged: () => setState(() {}),
        );
    }
  }

  Widget _toolButton(_VTool t, IconData icon, String label) {
    final on = _tool == t;
    return InkWell(
      onTap: () => setState(() {
        _tool = t;
        _sel = -1;
      }),
      child: SizedBox(
        width: 68,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: on ? Colors.blue : Colors.white10, borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: on ? Colors.white : Colors.white60, fontSize: 10, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  // ───────────── Simpan ─────────────

  Future<void> _save() async {
    if (_saving || !_ready) return;
    final path = widget.file.path;
    final fileName = path.split(Platform.pathSeparator).last;
    final stem = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final name = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(title: 'Simpan hasil edit', initial: '${stem}_EDIT', suffix: '.mp4'),
    );
    if (name == null || !mounted) return;
    await _vc.pause();
    setState(() {
      _saving = true;
      _progress = 0;
    });
    Timer? poll;
    try {
      final tmp = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outTmp = '${tmp.path}/edit_$ts.mp4';
      final fw = math.max(2, (_rw * _crop.width).round());
      final fh = math.max(2, (_rh * _crop.height).round());
      String? overlayPath;
      if (_items.isNotEmpty) {
        final png = await renderOverlayPng(_items, fw, fh);
        overlayPath = '${tmp.path}/ov_$ts.png';
        await File(overlayPath).writeAsBytes(png, flush: true);
      }
      poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        try {
          final p = await kEditChannel.invokeMethod<int>('editProgress');
          if (mounted && p != null && p >= 0) setState(() => _progress = p / 100);
        } catch (_) {}
      });
      await kEditChannel.invokeMethod<String>('editVideo', <String, dynamic>{
        'src': path,
        'dest': outTmp,
        'start': _range.start.round(),
        'end': _range.end >= _durMs - 50 ? -1 : _range.end.round(),
        'rotation': 90 * _quarter,
        'flip': _flip,
        'crop': [_crop.left, _crop.top, _crop.right, _crop.bottom],
        'filter': _filter.id,
        'mute': _mute,
        'overlay': overlayPath,
      });
      poll.cancel();
      final dir = widget.file.parent;
      var dest = File('${dir.path}/$name.mp4');
      var n = 1;
      while (await dest.exists()) {
        dest = File('${dir.path}/${name}_$n.mp4');
        n++;
      }
      await File(outTmp).copy(dest.path);
      try {
        await File(outTmp).delete();
        if (overlayPath != null) await File(overlayPath).delete();
      } catch (_) {}
      await scanMediaPaths([dest.path]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Video tersimpan: ${dest.path.split(Platform.pathSeparator).last}')));
        Navigator.pop(context, true);
      }
    } on PlatformException catch (e) {
      _toast('Gagal memproses video: ${e.message ?? e.code}');
    } catch (e) {
      _toast('Gagal menyimpan video: $e');
    } finally {
      poll?.cancel();
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t)));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('EDIT VIDEO', style: TextStyle(fontWeight: FontWeight.w800)),
          actions: [
            IconButton(tooltip: 'Simpan', onPressed: _saving || !_ready ? null : _save, icon: const Icon(Icons.save_outlined)),
          ],
        ),
        body: _error != null
            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white70)))
            : !_ready
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      Column(
                        children: [
                          Expanded(child: _preview()),
                          Container(
                            color: const Color(0xFF101114),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(children: [
                              IconButton(onPressed: _togglePlay, icon: Icon(_vc.value.isPlaying ? Icons.pause_circle : Icons.play_circle, color: Colors.white, size: 34)),
                              Text(_fmt(_vc.value.position.inMilliseconds.toDouble()), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              Expanded(
                                child: Slider(
                                  value: _vc.value.position.inMilliseconds.toDouble().clamp(0, _durMs).toDouble(),
                                  min: 0,
                                  max: _durMs,
                                  onChanged: (v) => _vc.seekTo(Duration(milliseconds: v.round())),
                                ),
                              ),
                            ]),
                          ),
                          SafeArea(
                            top: false,
                            child: Container(
                              color: const Color(0xFF101114),
                              padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                SizedBox(
                                  height: 66,
                                  child: ListView(scrollDirection: Axis.horizontal, children: [
                                    _toolButton(_VTool.trim, Icons.content_cut, 'Potong'),
                                    _toolButton(_VTool.crop, Icons.crop, 'Crop'),
                                    _toolButton(_VTool.rotate, Icons.rotate_90_degrees_cw, 'Putar'),
                                    _toolButton(_VTool.effect, Icons.auto_awesome, 'Efek'),
                                    _toolButton(_VTool.text, Icons.title, 'Teks'),
                                    _toolButton(_VTool.sticker, Icons.emoji_emotions_outlined, 'Stiker'),
                                    _toolButton(_VTool.watermark, Icons.branding_watermark, 'Watermark'),
                                  ]),
                                ),
                                const Divider(color: Colors.white12, height: 1),
                                const SizedBox(height: 6),
                                _panel(),
                              ]),
                            ),
                          ),
                        ],
                      ),
                      if (_saving)
                        Positioned.fill(
                          child: ColoredBox(
                            color: const Color(0xCC000000),
                            child: Center(
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(22),
                                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                                    SizedBox(width: 220, child: LinearProgressIndicator(value: _progress > 0 ? _progress : null)),
                                    const SizedBox(height: 14),
                                    Text('Memproses video... ${(_progress * 100).round()}%'),
                                    const SizedBox(height: 4),
                                    const Text('Jangan tutup aplikasi', style: TextStyle(fontSize: 12, color: Colors.black54)),
                                  ]),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }
}

// ───────────────────────── Kotak crop ─────────────────────────

class CropBox extends StatelessWidget {
  final Rect rect; // pecahan 0..1
  final double? aspect; // lebar/tinggi piksel, null = bebas
  final Size frame; // ukuran frame dalam piksel
  final ValueChanged<Rect> onChanged;
  const CropBox({super.key, required this.rect, required this.aspect, required this.frame, required this.onChanged});

  Rect _resize(int corner, Offset delta) {
    Offset anchor;
    Offset moving;
    switch (corner) {
      case 0:
        anchor = rect.bottomRight;
        moving = rect.topLeft + delta;
        break;
      case 1:
        anchor = rect.bottomLeft;
        moving = rect.topRight + delta;
        break;
      case 2:
        anchor = rect.topLeft;
        moving = rect.bottomRight + delta;
        break;
      default:
        anchor = rect.topRight;
        moving = rect.bottomLeft + delta;
    }
    final mx = moving.dx.clamp(0.0, 1.0).toDouble();
    final my = moving.dy.clamp(0.0, 1.0).toDouble();
    var w = (mx - anchor.dx).abs();
    var h = (my - anchor.dy).abs();
    final sx = mx >= anchor.dx ? 1.0 : -1.0;
    final sy = my >= anchor.dy ? 1.0 : -1.0;
    final a = aspect;
    if (a != null) {
      final k = frame.width / (a * frame.height);
      h = w * k;
      final maxH = sy > 0 ? 1 - anchor.dy : anchor.dy;
      if (h > maxH) {
        h = maxH;
        w = h / k;
      }
      final maxW = sx > 0 ? 1 - anchor.dx : anchor.dx;
      if (w > maxW) {
        w = maxW;
        h = w * k;
      }
    }
    w = math.max(w, .08);
    h = math.max(h, .08);
    final x2 = (anchor.dx + sx * w).clamp(0.0, 1.0).toDouble();
    final y2 = (anchor.dy + sy * h).clamp(0.0, 1.0).toDouble();
    return Rect.fromLTRB(math.min(anchor.dx, x2), math.min(anchor.dy, y2), math.max(anchor.dx, x2), math.max(anchor.dy, y2));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        final r = Rect.fromLTRB(rect.left * w, rect.top * h, rect.right * w, rect.bottom * h);
        final corners = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
        return Stack(
          children: [
            Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _CropDimPainter(r)))),
            Positioned.fromRect(
              rect: r,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) {
                  var nr = rect.shift(Offset(d.delta.dx / w, d.delta.dy / h));
                  var dx = 0.0;
                  var dy = 0.0;
                  if (nr.left < 0) dx = -nr.left;
                  if (nr.right > 1) dx = 1 - nr.right;
                  if (nr.top < 0) dy = -nr.top;
                  if (nr.bottom > 1) dy = 1 - nr.bottom;
                  nr = nr.shift(Offset(dx, dy));
                  onChanged(nr);
                },
                child: const SizedBox.expand(),
              ),
            ),
            for (var i = 0; i < 4; i++)
              Positioned(
                left: corners[i].dx - 24,
                top: corners[i].dy - 24,
                width: 48,
                height: 48,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) => onChanged(_resize(i, Offset(d.delta.dx / w, d.delta.dy / h))),
                  child: Center(
                    child: Container(width: 18, height: 18, decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, border: Border.all(color: Colors.blue, width: 3))),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CropDimPainter extends CustomPainter {
  final Rect hole;
  _CropDimPainter(this.hole);
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRect(hole));
    canvas.drawPath(path, Paint()..color = const Color(0x99000000));
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(hole, line);
    final thin = Paint()
      ..color = Colors.white54
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(hole.left + hole.width * i / 3, hole.top), Offset(hole.left + hole.width * i / 3, hole.bottom), thin);
      canvas.drawLine(Offset(hole.left, hole.top + hole.height * i / 3), Offset(hole.right, hole.top + hole.height * i / 3), thin);
    }
  }

  @override
  bool shouldRepaint(covariant _CropDimPainter old) => old.hole != hole;
}
