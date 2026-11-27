import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

// ───────────────────────── Util ─────────────────────────

bool isImagePath(String p) {
  final l = p.toLowerCase();
  return l.endsWith('.jpg') || l.endsWith('.jpeg') || l.endsWith('.png');
}

bool isVideoPath(String p) {
  final l = p.toLowerCase();
  return l.endsWith('.mp4') || l.endsWith('.mov') || l.endsWith('.3gp') || l.endsWith('.mkv') || l.endsWith('.webm');
}

bool isMediaPath(String p) => isImagePath(p) || isVideoPath(p);

String fileNameOf(File f) => f.path.split(Platform.pathSeparator).last;

String _captionOf(File f) => fileNameOf(f).replaceFirst(RegExp(r'\.[^.]+$'), '');

/// Urutan nama "alami": 2_ARA ... tampil sebelum 10_ARA ...
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final pa = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final pb = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  final n = math.min(pa.length, pb.length);
  for (var i = 0; i < n; i++) {
    final x = pa[i];
    final y = pb[i];
    final xd = RegExp(r'^\d').hasMatch(x);
    final yd = RegExp(r'^\d').hasMatch(y);
    int c;
    if (xd && yd) {
      final sx = x.replaceFirst(RegExp(r'^0+'), '');
      final sy = y.replaceFirst(RegExp(r'^0+'), '');
      c = sx.length != sy.length ? sx.length.compareTo(sy.length) : sx.compareTo(sy);
    } else {
      c = x.compareTo(y);
    }
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

/// Hanya karakter Latin-1 yang aman untuk font standar PDF.
String _pdfSafe(String s) => String.fromCharCodes(s.runes.map((c) => c < 256 ? c : 63));

// ───────────────────────── Pemrosesan gambar ─────────────────────────

/// Berjalan di isolate: gamma, penajaman, lalu encode JPEG.
Uint8List _encodeCellJob(Map<String, dynamic> a) {
  final w = a['w'] as int;
  final h = a['h'] as int;
  final data = Uint8List.fromList(a['rgba'] as Uint8List);
  final gamma = (a['gamma'] as num).toDouble();
  final sharpen = (a['sharpen'] as num).toDouble();
  final quality = a['quality'] as int;
  if ((gamma - 1).abs() > 0.01) {
    final lut = List<int>.generate(256, (i) => (255 * math.pow(i / 255, 1 / gamma)).round().clamp(0, 255).toInt());
    for (var i = 0; i + 3 < data.length; i += 4) {
      data[i] = lut[data[i]];
      data[i + 1] = lut[data[i + 1]];
      data[i + 2] = lut[data[i + 2]];
    }
  }
  var im = img.Image.fromBytes(width: w, height: h, bytes: data.buffer, numChannels: 4);
  if (sharpen > 0) {
    im = img.convolution(im, filter: [0, -sharpen, 0, -sharpen, 1 + 4 * sharpen, -sharpen, 0, -sharpen, 0]);
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: quality));
}

class _CellImage {
  final Uint8List bytes;
  final double w, h, dx, dy; // dalam mm, relatif terhadap kotak foto
  const _CellImage(this.bytes, this.w, this.h, this.dx, this.dy);
}

class _Paper {
  final String name;
  final double w, h; // mm, portrait
  const _Paper(this.name, this.w, this.h);
}

const List<_Paper> _papers = [
  _Paper('A4 Sheet', 210, 297),
  _Paper('A3 Sheet', 297, 420),
  _Paper('A5 Sheet', 148, 210),
  _Paper('Letter', 215.9, 279.4),
  _Paper('F4 / Folio', 215, 330),
  _Paper('4R (10 x 15 cm)', 102, 152),
];

const double _margin = 3; // mm, area cetak = kertas dikurangi 3 mm tiap sisi
const double _mmPerPt = 25.4 / 72;
const List<String> _fitNames = ['Tarik', 'Penuhi Kanvas', 'Citra Penuh', 'DPI'];
const List<String> _alignNames = ['Atas', 'Tengah', 'Bawah'];

// Kualitas cetak: resolusi gambar di PDF, kualitas JPEG, dan penajaman.
const List<String> _qualityLabels = ['Standar (150 dpi)', 'Tajam (220 dpi)', 'Tinggi (300 dpi)'];
const List<double> _qualityDpi = [150, 220, 300];
const List<int> _qualityJpeg = [88, 92, 95];
const List<double> _qualitySharpen = [0, 0.25, 0.4];
const double _previewDpi = 110;

// ───────────────────────── Halaman ─────────────────────────

class PrintPage extends StatefulWidget {
  final List<File> photos;
  final Future<List<File>> Function() loadPhotos;
  final bool pickFromGalleryOnStart;
  const PrintPage({super.key, required this.photos, required this.loadPhotos, this.pickFromGalleryOnStart = false});

  @override
  State<PrintPage> createState() => _PrintPageState();
}

class _PrintPageState extends State<PrintPage> {
  late List<File> _items;
  int _selected = -1;
  int _page = 0;
  bool _panelOpen = false;

  int _paperIndex = 0;
  bool _landscape = true;
  int _rows = 3;
  int _cols = 3;
  int _fontPt = 12; // 0 = tanpa nama
  int _quality = 0;
  int _interval = 6;
  int _fit = 1;
  int _dpi = 1200;
  int _align = 2;
  double _gamma = 1.0;
  double _gammaDraft = 1.0;
  bool _frame = false;
  bool _autoRotate = true;
  bool _gray = false;
  bool _sepia = false;

  final Map<String, _CellImage> _cells = {};
  final Set<String> _failed = {};
  final Map<String, String> _captionCache = {};
  final TransformationController _pz = TransformationController();
  bool _hiRes = false;
  bool _busy = false;
  String _busyText = '';

  @override
  void initState() {
    super.initState();
    _items = widget.photos.where((f) => isImagePath(f.path)).toList()..sort((a, b) => naturalCompare(fileNameOf(a), fileNameOf(b)));
    _pz.addListener(_onZoom);
    _renderPage();
    if (widget.pickFromGalleryOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pickFromDeviceGallery());
    }
  }

  @override
  void dispose() {
    _pz.dispose();
    super.dispose();
  }

  void _onZoom() {
    final hi = _pz.value.getMaxScaleOnAxis() > 1.6;
    if (hi != _hiRes) {
      setState(() => _hiRes = hi);
      _renderPage(); // render ulang lebih tajam saat di-zoom
    }
  }

  void _toggleZoom(Size size) {
    if (_pz.value.getMaxScaleOnAxis() > 1.05) {
      _pz.value = Matrix4.identity();
    } else {
      const z = 2.5;
      _pz.value = Matrix4.translationValues(-size.width * (z - 1) / 2, -size.height * (z - 1) / 2, 0) * Matrix4.diagonal3Values(z, z, 1);
    }
  }

  // ───────────── Geometri ─────────────

  _Paper get _paper => _papers[_paperIndex];
  double get _pageW => _landscape ? math.max(_paper.w, _paper.h) : math.min(_paper.w, _paper.h);
  double get _pageH => _landscape ? math.min(_paper.w, _paper.h) : math.max(_paper.w, _paper.h);
  double get _areaW => _pageW - 2 * _margin;
  double get _areaH => _pageH - 2 * _margin;
  double get _cellW => math.max(5, (_areaW - (_cols - 1) * _interval) / _cols);
  double get _cellH => math.max(5, (_areaH - (_rows - 1) * _interval) / _rows);
  double get _captionH => _fontPt == 0 ? 0 : _fontPt * _mmPerPt * 1.35 + 1.5;
  double get _photoH => math.max(4, _cellH - _captionH);
  int get _perPage => _rows * _cols;
  int get _pageCount => math.max(1, (_items.length / _perPage).ceil());

  String get _keyBase =>
      '${_cellW.toStringAsFixed(1)}x${_photoH.toStringAsFixed(1)}|$_fit|$_dpi|$_align|$_autoRotate|${_gamma.toStringAsFixed(2)}|$_gray|$_sepia';
  String get _cellKey => '$_keyBase|$_hiRes';

  /// Gambar preview untuk satu foto; bila versi resolusi saat ini belum siap,
  /// pakai versi lain agar layar tidak berkedip saat zoom.
  _CellImage? _cellFor(File f) => _cells['${f.path}|$_keyBase|$_hiRes'] ?? _cells['${f.path}|$_keyBase|${!_hiRes}'];


  String _fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  /// Memotong nama agar muat selebar sel (tanpa titik-titik, seperti program desktop).
  String _clipCaption(File f) {
    final full = _pdfSafe(_captionOf(f));
    final key = '${f.path}|${_cellW.toStringAsFixed(1)}|$_fontPt';
    final cached = _captionCache[key];
    if (cached != null) return cached;
    final maxWidth = _cellW / _mmPerPt * 0.96; // dalam satuan pt
    double width(String s) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: _fontPt.toDouble())),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      return tp.width;
    }

    var result = full;
    if (width(full) > maxWidth) {
      var lo = 0;
      var hi = full.length;
      while (lo < hi) {
        final mid = (lo + hi + 1) ~/ 2;
        if (width(full.substring(0, mid)) <= maxWidth) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      result = full.substring(0, lo);
    }
    _captionCache[key] = result;
    return result;
  }

  // ───────────── Render sel ─────────────

  List<File> _pageFiles(int page) {
    final start = page * _perPage;
    if (start >= _items.length) return const [];
    return _items.sublist(start, math.min(_items.length, start + _perPage));
  }

  void _invalidate() {
    _cells.clear();
    _captionCache.clear();
    _page = _page.clamp(0, _pageCount - 1).toInt();
    setState(() {});
    _renderPage();
  }

  /// Membuat gambar satu sel. Decode memakai codec native (cepat) dengan ukuran
  /// secukupnya, digambar lewat Canvas, lalu hanya encode JPEG di isolate.
  Future<_CellImage?> _renderCell(File f, {required double dpiOut, required int jpegQuality, required double sharpen}) async {
    final boxW = _cellW;
    final boxH = _photoH;
    final fit = _fit;
    final dpi = _dpi.toDouble();
    final align = _align;
    final autoRotate = _autoRotate;
    final gamma = _gamma;
    final gray = _gray;
    final sepia = _sepia;
    final ppm = dpiOut / 25.4;

    ui.ImageDescriptor? desc;
    ui.Codec? codec;
    ui.Image? decoded;
    ui.Image? drawn;
    try {
      final bytes = await f.readAsBytes();
      final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
      desc = await ui.ImageDescriptor.encoded(buf);
      buf.dispose();
      final ow = desc.width;
      final oh = desc.height;
      if (ow <= 0 || oh <= 0) return null;

      final rotate = autoRotate && ow != oh && ((ow > oh) != (boxW > boxH));
      final ew = rotate ? oh : ow;
      final eh = rotate ? ow : oh;

      double rw;
      double rh;
      var fx = 1.0;
      var fy = 1.0;
      switch (fit) {
        case 0: // Tarik
          rw = boxW;
          rh = boxH;
          break;
        case 1: // Penuhi kanvas
          rw = boxW;
          rh = boxH;
          final ia = ew / eh;
          final ba = boxW / boxH;
          if (ia > ba) {
            fx = ba / ia;
          } else {
            fy = ia / ba;
          }
          break;
        case 2: // Citra penuh
          final sc = math.min(boxW / ew, boxH / eh);
          rw = ew * sc;
          rh = eh * sc;
          break;
        default: // DPI
          final physW = ew / dpi * 25.4;
          final physH = eh / dpi * 25.4;
          rw = math.min(physW, boxW);
          rh = math.min(physH, boxH);
          fx = rw / physW;
          fy = rh / physH;
      }

      final wantW = rw * ppm;
      final wantH = rh * ppm;
      final cap = math.min(1.0, math.min(ew * fx / wantW, eh * fy / wantH));
      final tw = math.max(1, (wantW * cap).round());
      final th = math.max(1, (wantH * cap).round());

      final decW = (rotate ? th / fy : tw / fx).ceil().clamp(1, ow).toInt();
      codec = await desc.instantiateCodec(targetWidth: decW >= ow ? null : decW);
      decoded = (await codec.getNextFrame()).image;
      final dw = decoded.width.toDouble();
      final dh = decoded.height.toDouble();

      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      final paint = Paint()
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true;
      if (sepia) {
        paint.colorFilter = const ColorFilter.matrix(<double>[
          .393, .769, .189, 0, 0, //
          .349, .686, .168, 0, 0,
          .272, .534, .131, 0, 0,
          0, 0, 0, 1, 0,
        ]);
      } else if (gray) {
        paint.colorFilter = const ColorFilter.matrix(<double>[
          .299, .587, .114, 0, 0, //
          .299, .587, .114, 0, 0,
          .299, .587, .114, 0, 0,
          0, 0, 0, 1, 0,
        ]);
      }
      if (!rotate) {
        canvas.drawImageRect(
          decoded,
          Rect.fromLTWH((dw - dw * fx) / 2, (dh - dh * fy) / 2, dw * fx, dh * fy),
          Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
          paint,
        );
      } else {
        canvas.translate(tw.toDouble(), 0);
        canvas.rotate(math.pi / 2);
        canvas.drawImageRect(
          decoded,
          Rect.fromLTWH((dw - dw * fy) / 2, (dh - dh * fx) / 2, dw * fy, dh * fx),
          Rect.fromLTWH(0, 0, th.toDouble(), tw.toDouble()),
          paint,
        );
      }
      final pic = rec.endRecording();
      drawn = await pic.toImage(tw, th);
      pic.dispose();
      final bd = await drawn.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) return null;
      final rgba = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);

      final jpg = await compute(_encodeCellJob, <String, dynamic>{
        'w': tw,
        'h': th,
        'rgba': rgba,
        'gamma': gamma,
        'sharpen': sharpen,
        'quality': jpegQuality,
      });
      final dx = (boxW - rw) / 2;
      final dy = align == 0 ? 0.0 : (align == 1 ? (boxH - rh) / 2 : boxH - rh);
      return _CellImage(jpg, rw, rh, dx, dy);
    } catch (_) {
      return null;
    } finally {
      drawn?.dispose();
      decoded?.dispose();
      codec?.dispose();
      desc?.dispose();
    }
  }

  Future<void> _renderOne(File f) async {
    if (_failed.contains(f.path)) return;
    final key = _cellKey;
    final id = '${f.path}|$key';
    if (_cells.containsKey(id)) return;
    final cell = await _renderCell(f, dpiOut: _hiRes ? 250 : _previewDpi, jpegQuality: 82, sharpen: 0);
    if (key != _cellKey) return; // pengaturan sudah berubah
    if (cell == null) {
      _failed.add(f.path);
    } else {
      _cells[id] = cell;
    }
    if (mounted) setState(() {});
  }

  Future<void> _renderBatch(List<File> files, {void Function(int done)? onProgress}) async {
    var done = 0;
    for (var i = 0; i < files.length; i += 4) {
      final batch = files.skip(i).take(4).toList();
      await Future.wait(batch.map(_renderOne));
      done += batch.length;
      onProgress?.call(done);
    }
  }

  Future<void> _renderPage() => _renderBatch(_pageFiles(_page));

  // ───────────── Aksi ─────────────

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _addPhotos() async {
    final src = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(alignment: Alignment.centerLeft, child: Text('Tambah foto dari', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_back_outlined),
              title: const Text('Foto Cam Dat'),
              subtitle: const Text('Foto hasil jepretan aplikasi ini'),
              onTap: () => Navigator.pop(ctx, 'app'),
            ),
            ListTile(
              leading: const Icon(Icons.phone_android),
              title: const Text('Galeri Android'),
              subtitle: const Text('Pilih foto apa saja yang ada di HP'),
              onTap: () => Navigator.pop(ctx, 'device'),
            ),
          ],
        ),
      ),
    );
    if (src == 'app') {
      await _addFromApp();
    } else if (src == 'device') {
      await _pickFromDeviceGallery();
    }
  }

  Future<void> _pickFromDeviceGallery() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: true);
      if (res == null || !mounted) return;
      final have = _items.map((f) => f.path).toSet();
      final added = <File>[];
      for (final pf in res.files) {
        final path = pf.path;
        if (path == null || have.contains(path)) continue;
        have.add(path);
        added.add(File(path));
      }
      if (added.isEmpty) {
        _toast('Tidak ada foto baru yang ditambahkan.');
        return;
      }
      setState(() {
        _items = [..._items, ...added]..sort((a, b) => naturalCompare(fileNameOf(a), fileNameOf(b)));
      });
      _renderPage();
    } catch (e) {
      _toast('Gagal membuka Galeri: $e');
    }
  }

  Future<void> _addFromApp() async {
    final all = await widget.loadPhotos();
    if (!mounted) return;
    final have = _items.map((f) => f.path).toSet();
    final candidates = all.where((f) => isImagePath(f.path) && !have.contains(f.path)).toList()
      ..sort((a, b) => naturalCompare(fileNameOf(a), fileNameOf(b)));
    if (candidates.isEmpty) {
      _toast('Semua foto Cam Dat sudah ada dalam daftar cetak.');
      return;
    }
    final picked = await showModalBottomSheet<List<File>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _AddPhotosSheet(candidates: candidates),
    );
    if (picked == null || picked.isEmpty) return;
    setState(() {
      _items = [..._items, ...picked]..sort((a, b) => naturalCompare(fileNameOf(a), fileNameOf(b)));
    });
    _renderPage();
  }

  Future<void> _removeSelected() async {
    if (_items.isEmpty) return;
    if (_selected >= 0 && _selected < _items.length) {
      setState(() {
        _items.removeAt(_selected);
        _selected = -1;
        _page = _page.clamp(0, _pageCount - 1).toInt();
      });
      _renderPage();
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kosongkan daftar cetak?'),
        content: const Text('Foto tidak dihapus dari galeri, hanya dikeluarkan dari daftar cetak.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('BATAL')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('KOSONGKAN')),
        ],
      ),
    );
    if (yes != true) return;
    setState(() {
      _items.clear();
      _selected = -1;
      _page = 0;
    });
  }

  void _resetAll() {
    _rows = 3;
    _cols = 3;
    _fontPt = 12;
    _quality = 0;
    _interval = 6;
    _fit = 1;
    _dpi = 1200;
    _align = 2;
    _gamma = 1.0;
    _gammaDraft = 1.0;
    _frame = false;
    _autoRotate = true;
    _gray = false;
    _sepia = false;
    _invalidate();
  }

  Future<Uint8List> _buildPdf(Map<String, _CellImage> cells) async {
    const mm = PdfPageFormat.mm;
    final doc = pw.Document();
    final fmt = PdfPageFormat(_pageW * mm, _pageH * mm);
    for (var pg = 0; pg < _pageCount; pg++) {
      final files = _pageFiles(pg);
      final children = <pw.Widget>[];
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        final r = i ~/ _cols;
        final c = i % _cols;
        final x = (_margin + c * (_cellW + _interval)) * mm;
        final y = (_margin + r * (_cellH + _interval)) * mm;
        final cell = cells[f.path];
        if (cell != null) {
          final w = cell.w * mm;
          final h = cell.h * mm;
          children.add(
            pw.Positioned(
              left: x + cell.dx * mm,
              top: y + cell.dy * mm,
              child: pw.Stack(
                children: [
                  pw.Image(pw.MemoryImage(cell.bytes), width: w, height: h, fit: pw.BoxFit.fill),
                  if (_frame)
                    pw.Container(
                      width: w,
                      height: h,
                      decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.black, width: .6)),
                    ),
                ],
              ),
            ),
          );
        }
        if (_fontPt > 0) {
          children.add(
          pw.Positioned(
            left: x,
            top: y + _photoH * mm,
            child: pw.Container(
              width: _cellW * mm,
              height: _captionH * mm,
              alignment: pw.Alignment.center,
              child: pw.Text(
                _clipCaption(f),
                maxLines: 1,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: _fontPt.toDouble(), color: PdfColors.black),
              ),
            ),
          ),
          );
        }
      }
      doc.addPage(
        pw.Page(
          pageFormat: fmt,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Stack(fit: pw.StackFit.expand, children: children),
        ),
      );
    }
    return doc.save();
  }

  Future<void> _print() async {
    if (_items.isEmpty) {
      _toast('Belum ada foto untuk dicetak. Tekan "Tambah".');
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyText = 'Menyiapkan foto...';
    });
    Uint8List? bytes;
    try {
      final todo = _items.where((f) => !_failed.contains(f.path)).toList();
      final printCells = <String, _CellImage>{};
      var done = 0;
      for (var i = 0; i < todo.length; i += 3) {
        final batch = todo.skip(i).take(3).toList();
        await Future.wait(batch.map((f) async {
          final c = await _renderCell(f, dpiOut: _qualityDpi[_quality], jpegQuality: _qualityJpeg[_quality], sharpen: _qualitySharpen[_quality]);
          if (c != null) printCells[f.path] = c;
        }));
        done += batch.length;
        if (mounted) setState(() => _busyText = 'Menyiapkan foto... $done/${todo.length}');
      }
      if (mounted) setState(() => _busyText = 'Membuat dokumen...');
      bytes = await _buildPdf(printCells);
    } catch (e) {
      _toast('Gagal menyiapkan cetakan: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (bytes == null || !mounted) return;
    final data = bytes;
    try {
      await Printing.layoutPdf(
        onLayout: (_) async => data,
        name: 'Cetak_Foto',
        format: PdfPageFormat(_pageW * PdfPageFormat.mm, _pageH * PdfPageFormat.mm),
      );
    } catch (e) {
      _toast('Gagal membuka dialog cetak: $e');
    }
  }

  Future<void> _showPrinterSetup() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Atur Pencetak', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text(
                'Printer dipilih pada dialog cetak Android saat menekan "Cetak...". Di sini Anda mengatur ukuran dan arah kertas.',
                style: TextStyle(fontSize: 12.5, color: Colors.black54),
              ),
              const SizedBox(height: 16),
              const Text('Kertas', style: TextStyle(fontWeight: FontWeight.w600)),
              for (var i = 0; i < _papers.length; i++)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_paperIndex == i ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      color: _paperIndex == i ? Theme.of(ctx).colorScheme.primary : null),
                  title: Text('${_papers[i].name}, ${_fmt(_papers[i].w)} x ${_fmt(_papers[i].h)} mm'),
                  onTap: () {
                    _paperIndex = i;
                    setSheet(() {});
                    _invalidate();
                  },
                ),
              const SizedBox(height: 12),
              const Text('Arah kertas', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, icon: Icon(Icons.crop_landscape), label: Text('Landscape')),
                  ButtonSegment(value: false, icon: Icon(Icons.crop_portrait), label: Text('Portrait')),
                ],
                selected: {_landscape},
                onSelectionChanged: (s) {
                  _landscape = s.first;
                  setSheet(() {});
                  _invalidate();
                },
              ),
              const SizedBox(height: 16),
              const Text('Kualitas cetak', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 0, label: Text('Standar')),
                  ButtonSegment(value: 1, label: Text('Tajam')),
                  ButtonSegment(value: 2, label: Text('Tinggi')),
                ],
                selected: {_quality},
                onSelectionChanged: (v) {
                  setState(() => _quality = v.first);
                  setSheet(() {});
                },
              ),
              const SizedBox(height: 6),
              Text(
                '${_qualityLabels[_quality]}${_quality > 0 ? ' + penajaman' : ''}. Makin tinggi, gambar makin detail tetapi proses dan antrean cetak lebih lama. '
                'Bila hasil cetak bergaris, pilih juga kualitas "High/Best" pada opsi printer di dialog cetak Android dan bersihkan head printer.',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('SELESAI')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────── UI ─────────────

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    return Scaffold(
      appBar: AppBar(title: Text('CETAK FOTO (${_items.length})')),
      body: Stack(
        children: [
          Column(
            children: [
              _thumbStrip(),
              Expanded(child: _previewArea()),
              _pager(),
              _infoBar(),
              _actionButtons(),
              _settingsPanel(screenH),
            ],
          ),
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0x88000000),
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 14),
                          Text(_busyText),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _thumbStrip() {
    return Container(
      height: 78,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: _items.isEmpty
                ? const Center(child: Text('Daftar kosong. Tekan "Tambah".', style: TextStyle(color: Colors.black54)))
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final sel = i == _selected;
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _selected = sel ? -1 : i;
                            _page = i ~/ _perPage;
                          });
                          _renderPage();
                        },
                        child: Container(
                          width: 78,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: BoxDecoration(
                            border: Border.all(color: sel ? Colors.blue : Colors.black26, width: sel ? 3 : 1),
                            color: Colors.black12,
                          ),
                          child: Image.file(_items[i], fit: BoxFit.cover, cacheWidth: 180, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image)),
                        ),
                      );
                    },
                  ),
          ),
          IconButton(
            tooltip: _selected >= 0 ? 'Keluarkan foto terpilih' : 'Kosongkan daftar',
            onPressed: _items.isEmpty ? null : _removeSelected,
            icon: Icon(_selected >= 0 ? Icons.remove_circle_outline : Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  Widget _previewArea() {
    return Container(
      color: const Color(0xFFD7DADF),
      child: LayoutBuilder(
        builder: (context, c) {
          final scale = math.min((c.maxWidth - 16) / _pageW, (c.maxHeight - 16) / _pageH);
          if (scale <= 0) return const SizedBox.shrink();
          final files = _pageFiles(_page);
          final cells = <Widget>[];
          for (var i = 0; i < files.length; i++) {
            final f = files[i];
            final r = i ~/ _cols;
            final col = i % _cols;
            final x = (_margin + col * (_cellW + _interval)) * scale;
            final y = (_margin + r * (_cellH + _interval)) * scale;
            final cell = _cellFor(f);
            final failed = _failed.contains(f.path);
            cells.add(
              Positioned(
                left: x,
                top: y,
                width: _cellW * scale,
                height: _cellH * scale,
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    if (cell != null)
                      Positioned(
                        left: cell.dx * scale,
                        top: cell.dy * scale,
                        width: cell.w * scale,
                        height: cell.h * scale,
                        child: Container(
                          foregroundDecoration: _frame ? BoxDecoration(border: Border.all(color: Colors.black, width: 1)) : null,
                          child: Image.memory(cell.bytes, fit: BoxFit.fill, gaplessPlayback: true),
                        ),
                      )
                    else
                      Positioned(
                        left: 0,
                        top: 0,
                        width: _cellW * scale,
                        height: _photoH * scale,
                        child: ColoredBox(
                          color: const Color(0xFFEEEEEE),
                          child: Center(
                            child: failed
                                ? const Icon(Icons.broken_image, color: Colors.black38)
                                : const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                          ),
                        ),
                      ),
                    if (_fontPt > 0)
                    Positioned(
                      left: 0,
                      top: _photoH * scale,
                      width: _cellW * scale,
                      height: _captionH * scale,
                      child: Center(
                        child: Text(
                          _clipCaption(f),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.clip,
                          style: TextStyle(color: Colors.black, fontSize: _fontPt * _mmPerPt * scale),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return GestureDetector(
            onDoubleTap: () => _toggleZoom(c.biggest),
            child: InteractiveViewer(
              transformationController: _pz,
              minScale: 1,
              maxScale: 8,
              child: SizedBox(
                width: c.maxWidth,
                height: c.maxHeight,
                child: Center(
                  child: Container(
                    width: _pageW * scale,
                    height: _pageH * scale,
                    decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(blurRadius: 6, color: Colors.black26)]),
                    child: Stack(children: cells),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _pager() {
    final pages = _pageCount;
    return Container(
      color: const Color(0xFFD7DADF),
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: _page > 0
                ? () {
                    _pz.value = Matrix4.identity();
                    setState(() => _page--);
                    _renderPage();
                  }
                : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text('Page ${_page + 1}/$pages', style: const TextStyle(fontWeight: FontWeight.w600)),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: _page < pages - 1
                ? () {
                    _pz.value = Matrix4.identity();
                    setState(() => _page++);
                    _renderPage();
                  }
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  Widget _infoBar() {
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Text(
        '${_paper.name}, ${_fmt(_pageW)} x ${_fmt(_pageH)} mm  •  Area cetak ${_fmt(_areaW)} x ${_fmt(_areaH)} mm\n'
        'Ukuran foto ${_fmt(double.parse(_cellW.toStringAsFixed(0)))} x ${_fmt(double.parse(_photoH.toStringAsFixed(0)))} mm  •  $_perPage foto per halaman',
        style: const TextStyle(fontSize: 11.5, color: Colors.black87),
      ),
    );
  }

  Widget _actionButtons() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(onPressed: _busy ? null : _addPhotos, icon: const Icon(Icons.add), label: const Text('Tambah')),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: FilledButton.icon(onPressed: _busy ? null : _print, icon: const Icon(Icons.print), label: const Text('Cetak...')),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _showPrinterSetup,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const FittedBox(child: Text('Atur Pencetak')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsPanel(double screenH) {
    final height = _panelOpen ? math.min(screenH * 0.42, 380.0) : 0.0;
    return Container(
      color: const Color(0xFFF2F3F5),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => setState(() => _panelOpen = !_panelOpen),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.tune, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Cetak Thumbnail', style: TextStyle(fontWeight: FontWeight.w700))),
                    Text(_panelOpen ? 'Tutup' : 'Atur', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                    Icon(_panelOpen ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up),
                  ],
                ),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: height,
              child: _panelOpen ? SingleChildScrollView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 12), child: _settingsBody()) : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, Widget control) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          control,
        ],
      ),
    );
  }

  Widget _intDropdown(int value, List<int> items, String Function(int) label, ValueChanged<int> onChanged) {
    return DropdownButton<int>(
      value: value,
      isDense: true,
      items: [for (final v in items) DropdownMenuItem(value: v, child: Text(label(v)))],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }

  Widget _settingsBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row('Baris per halaman', _intDropdown(_rows, const [1, 2, 3, 4, 5, 6, 7, 8], (v) => '$v Baris', (v) {
          _rows = v;
          _invalidate();
        })),
        _row('Kolom per halaman', _intDropdown(_cols, const [1, 2, 3, 4, 5, 6, 7, 8], (v) => '$v Kolom', (v) {
          _cols = v;
          _invalidate();
        })),
        _row('Tinggi nama berkas', _intDropdown(_fontPt, const [0, 8, 9, 10, 12, 14, 16, 18, 20], (v) => v == 0 ? 'None (Tanpa Nama)' : '$v pt', (v) {
          _fontPt = v;
          _invalidate();
        })),
        _row(
          'Interval (mm)',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: _interval > 0
                    ? () {
                        _interval--;
                        _invalidate();
                      }
                    : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              SizedBox(width: 28, child: Text('$_interval', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700))),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: _interval < 30
                    ? () {
                        _interval++;
                        _invalidate();
                      }
                    : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
        ),
        const Divider(height: 18),
        Wrap(
          spacing: 8,
          children: [
            for (var i = 0; i < _fitNames.length; i++)
              ChoiceChip(
                label: Text(_fitNames[i]),
                selected: _fit == i,
                onSelected: (_) {
                  _fit = i;
                  _invalidate();
                },
              ),
          ],
        ),
        _row(
          'Resolusi (DPI)',
          DropdownButton<int>(
            value: _dpi,
            isDense: true,
            items: [for (final v in const [72, 96, 150, 200, 300, 600, 1200]) DropdownMenuItem(value: v, child: Text('$v DPI'))],
            onChanged: _fit == 3
                ? (v) {
                    if (v == null) return;
                    _dpi = v;
                    _invalidate();
                  }
                : null,
          ),
        ),
        _row('Ratakan foto', _intDropdown(_align, const [0, 1, 2], (v) => _alignNames[v], (v) {
          _align = v;
          _invalidate();
        })),
        const Divider(height: 18),
        Row(
          children: [
            const Text('Gamma', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: _gammaDraft == 1.0
                  ? null
                  : () {
                      _gamma = 1.0;
                      _gammaDraft = 1.0;
                      _invalidate();
                    },
              child: const Text('Inisialisasi'),
            ),
            const Spacer(),
            Text(_gammaDraft.toStringAsFixed(2), style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        Slider(
          value: _gammaDraft,
          min: 0.3,
          max: 3.0,
          onChanged: (v) => setState(() => _gammaDraft = double.parse(v.toStringAsFixed(2))),
          onChangeEnd: (_) {
            _gamma = _gammaDraft;
            _invalidate();
          },
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Tampilkan bingkai foto'),
          value: _frame,
          onChanged: (v) => setState(() => _frame = v ?? false),
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Otomatis Rotasi foto'),
          value: _autoRotate,
          onChanged: (v) {
            _autoRotate = v ?? true;
            _invalidate();
          },
        ),
        Wrap(
          spacing: 8,
          children: [
            FilterChip(
              label: const Text('Skala Abu-abu'),
              selected: _gray,
              onSelected: (v) {
                _gray = v;
                if (v) _sepia = false;
                _invalidate();
              },
            ),
            FilterChip(
              label: const Text('Sepia'),
              selected: _sepia,
              onSelected: (v) {
                _sepia = v;
                if (v) _gray = false;
                _invalidate();
              },
            ),
            ActionChip(label: const Text('Ulang'), avatar: const Icon(Icons.restart_alt, size: 18), onPressed: _resetAll),
          ],
        ),
      ],
    );
  }
}

// ───────────────────────── Sheet: tambah foto ─────────────────────────

class _AddPhotosSheet extends StatefulWidget {
  final List<File> candidates;
  const _AddPhotosSheet({required this.candidates});
  @override
  State<_AddPhotosSheet> createState() => _AddPhotosSheetState();
}

class _AddPhotosSheetState extends State<_AddPhotosSheet> {
  final Set<String> _picked = {};

  @override
  Widget build(BuildContext context) {
    final all = widget.candidates;
    final allSelected = _picked.length == all.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
          child: Row(
            children: [
              Expanded(child: Text('Tambah foto (${_picked.length} dipilih)', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
              TextButton(
                onPressed: () => setState(() {
                  if (allSelected) {
                    _picked.clear();
                  } else {
                    _picked.addAll(all.map((f) => f.path));
                  }
                }),
                child: Text(allSelected ? 'Batal semua' : 'Pilih semua'),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4, childAspectRatio: .85),
            itemCount: all.length,
            itemBuilder: (_, i) {
              final f = all[i];
              final sel = _picked.contains(f.path);
              return GestureDetector(
                onTap: () => setState(() {
                  if (!_picked.remove(f.path)) _picked.add(f.path);
                }),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Column(
                      children: [
                        Expanded(child: Image.file(f, fit: BoxFit.cover, width: double.infinity, cacheWidth: 300)),
                        Text(_captionOf(f), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9)),
                      ],
                    ),
                    if (sel) Container(decoration: BoxDecoration(color: Colors.blue.withValues(alpha: .25), border: Border.all(color: Colors.blue, width: 3))),
                    Positioned(
                      left: 4,
                      top: 4,
                      child: Icon(sel ? Icons.check_circle : Icons.radio_button_unchecked, color: sel ? Colors.blue : Colors.white, size: 22, shadows: const [Shadow(blurRadius: 4, color: Colors.black54)]),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, all.where((f) => _picked.contains(f.path)).toList()),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: Text('TAMBAHKAN ${_picked.length} FOTO'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
