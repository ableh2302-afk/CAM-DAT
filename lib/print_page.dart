import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

// ───────────────────────── Util ─────────────────────────

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

// ───────────────────────── Pemrosesan gambar (isolate) ─────────────────────────

/// Membuat salinan ringan (maks 1800 px) agar pengaturan bisa diubah dengan cepat.
Map<String, dynamic> _printBaseJob(Uint8List raw) {
  var im = img.decodeImage(raw);
  if (im == null) throw Exception('Foto tidak dapat dibaca.');
  im = img.bakeOrientation(im);
  final ow = im.width;
  final oh = im.height;
  const maxSide = 1800;
  if (math.max(ow, oh) > maxSide) {
    im = ow >= oh ? img.copyResize(im, width: maxSide) : img.copyResize(im, height: maxSide);
  }
  return {
    'bytes': Uint8List.fromList(img.encodeJpg(im, quality: 90)),
    'ow': ow,
    'oh': oh,
  };
}

/// Menghasilkan gambar satu sel sesuai mode (tarik / penuhi kanvas / citra penuh / DPI),
/// gamma, abu-abu dan sepia. Hasil dipakai persis sama untuk preview dan PDF.
Map<String, dynamic> _printCellJob(Map<String, dynamic> a) {
  var im = img.decodeImage(a['bytes'] as Uint8List);
  if (im == null) throw Exception('Foto tidak dapat dibaca.');
  var ow = a['ow'] as int;
  var oh = a['oh'] as int;
  final boxW = (a['boxW'] as num).toDouble();
  final boxH = (a['boxH'] as num).toDouble();
  final fit = a['fit'] as int;
  final dpi = (a['dpi'] as num).toDouble();
  final align = a['align'] as int;
  final autoRotate = a['rotate'] as bool;
  final gamma = (a['gamma'] as num).toDouble();
  final gray = a['gray'] as bool;
  final sepia = a['sepia'] as bool;

  const outDpi = 200.0;
  const ppm = outDpi / 25.4;

  if (autoRotate && im.width != im.height && ((im.width > im.height) != (boxW > boxH))) {
    im = img.copyRotate(im, angle: 90);
    final t = ow;
    ow = oh;
    oh = t;
  }

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
      final ia = im.width / im.height;
      final ba = boxW / boxH;
      if (ia > ba) {
        fx = ba / ia;
      } else {
        fy = ia / ba;
      }
      break;
    case 2: // Citra penuh
      final s = math.min(boxW / im.width, boxH / im.height);
      rw = im.width * s;
      rh = im.height * s;
      break;
    default: // DPI
      final physW = ow / dpi * 25.4;
      final physH = oh / dpi * 25.4;
      rw = math.min(physW, boxW);
      rh = math.min(physH, boxH);
      fx = rw / physW;
      fy = rh / physH;
  }

  var out = im;
  if (fx < 0.999 || fy < 0.999) {
    final cw = math.max(1, (im.width * fx).round());
    final ch = math.max(1, (im.height * fy).round());
    out = img.copyCrop(im, x: (im.width - cw) ~/ 2, y: (im.height - ch) ~/ 2, width: cw, height: ch);
  }

  final scale = math.min(1.0, out.width / (rw * ppm));
  final tw = math.max(1, (rw * ppm * scale).round());
  final th = math.max(1, (rh * ppm * scale).round());
  if (tw != out.width || th != out.height) {
    out = img.copyResize(out, width: tw, height: th, interpolation: img.Interpolation.average);
  }

  final needGamma = (gamma - 1).abs() > 0.01;
  if (needGamma || gray || sepia) {
    final lut = List<int>.generate(
      256,
      (i) => needGamma ? (255 * math.pow(i / 255, 1 / gamma)).round().clamp(0, 255).toInt() : i,
    );
    for (final p in out) {
      var r = lut[p.r.toInt().clamp(0, 255).toInt()].toDouble();
      var g = lut[p.g.toInt().clamp(0, 255).toInt()].toDouble();
      var b = lut[p.b.toInt().clamp(0, 255).toInt()].toDouble();
      if (gray) {
        final l = .299 * r + .587 * g + .114 * b;
        r = l;
        g = l;
        b = l;
      }
      if (sepia) {
        final nr = .393 * r + .769 * g + .189 * b;
        final ng = .349 * r + .686 * g + .168 * b;
        final nb = .272 * r + .534 * g + .131 * b;
        r = nr;
        g = ng;
        b = nb;
      }
      p.r = r.round().clamp(0, 255).toInt();
      p.g = g.round().clamp(0, 255).toInt();
      p.b = b.round().clamp(0, 255).toInt();
    }
  }

  final dx = (boxW - rw) / 2;
  final dy = align == 0 ? 0.0 : (align == 1 ? (boxH - rh) / 2 : boxH - rh);
  return {
    'bytes': Uint8List.fromList(img.encodeJpg(out, quality: 88)),
    'w': rw,
    'h': rh,
    'dx': dx,
    'dy': dy,
  };
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

// ───────────────────────── Halaman ─────────────────────────

class PrintPage extends StatefulWidget {
  final List<File> photos;
  final Future<List<File>> Function() loadPhotos;
  const PrintPage({super.key, required this.photos, required this.loadPhotos});

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
  int _fontPt = 12;
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

  final Map<String, Future<Map<String, dynamic>>> _baseFutures = {};
  final Map<String, _CellImage> _cells = {};
  final Set<String> _failed = {};
  final Map<String, String> _captionCache = {};
  bool _busy = false;
  String _busyText = '';

  @override
  void initState() {
    super.initState();
    _items = [...widget.photos]..sort((a, b) => naturalCompare(fileNameOf(a), fileNameOf(b)));
    _renderPage();
  }

  // ───────────── Geometri ─────────────

  _Paper get _paper => _papers[_paperIndex];
  double get _pageW => _landscape ? math.max(_paper.w, _paper.h) : math.min(_paper.w, _paper.h);
  double get _pageH => _landscape ? math.min(_paper.w, _paper.h) : math.max(_paper.w, _paper.h);
  double get _areaW => _pageW - 2 * _margin;
  double get _areaH => _pageH - 2 * _margin;
  double get _cellW => math.max(5, (_areaW - (_cols - 1) * _interval) / _cols);
  double get _cellH => math.max(5, (_areaH - (_rows - 1) * _interval) / _rows);
  double get _captionH => _fontPt * _mmPerPt * 1.35 + 1.5;
  double get _photoH => math.max(4, _cellH - _captionH);
  int get _perPage => _rows * _cols;
  int get _pageCount => math.max(1, (_items.length / _perPage).ceil());

  String get _cellKey =>
      '${_cellW.toStringAsFixed(1)}x${_photoH.toStringAsFixed(1)}|$_fit|$_dpi|$_align|$_autoRotate|${_gamma.toStringAsFixed(2)}|$_gray|$_sepia';

  String _cellId(File f) => '${f.path}|$_cellKey';

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

  Future<Map<String, dynamic>> _baseFor(File f) {
    return _baseFutures.putIfAbsent(f.path, () async {
      final raw = await f.readAsBytes();
      return compute(_printBaseJob, raw);
    });
  }

  Future<void> _renderOne(File f) async {
    if (_failed.contains(f.path)) return;
    final key = _cellKey;
    final id = '${f.path}|$key';
    if (_cells.containsKey(id)) return;
    try {
      final base = await _baseFor(f);
      final res = await compute(_printCellJob, <String, dynamic>{
        'bytes': base['bytes'],
        'ow': base['ow'],
        'oh': base['oh'],
        'boxW': _cellW,
        'boxH': _photoH,
        'fit': _fit,
        'dpi': _dpi,
        'align': _align,
        'rotate': _autoRotate,
        'gamma': _gamma,
        'gray': _gray,
        'sepia': _sepia,
      });
      if (key != _cellKey) return; // pengaturan sudah berubah
      _cells[id] = _CellImage(
        res['bytes'] as Uint8List,
        (res['w'] as num).toDouble(),
        (res['h'] as num).toDouble(),
        (res['dx'] as num).toDouble(),
        (res['dy'] as num).toDouble(),
      );
    } catch (_) {
      _failed.add(f.path);
    }
    if (mounted) setState(() {});
  }

  Future<void> _renderBatch(List<File> files, {void Function(int done)? onProgress}) async {
    var done = 0;
    for (var i = 0; i < files.length; i += 3) {
      final batch = files.skip(i).take(3).toList();
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
    final all = await widget.loadPhotos();
    if (!mounted) return;
    final have = _items.map((f) => f.path).toSet();
    final candidates = all.where((f) => !have.contains(f.path)).toList()
      ..sort((a, b) => naturalCompare(fileNameOf(a), fileNameOf(b)));
    if (candidates.isEmpty) {
      _toast('Semua foto sudah ada dalam daftar cetak.');
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

  Future<Uint8List> _buildPdf() async {
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
        final cell = _cells[_cellId(f)];
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
      final todo = _items.where((f) => !_cells.containsKey(_cellId(f)) && !_failed.contains(f.path)).toList();
      await _renderBatch(todo, onProgress: (d) {
        if (mounted) setState(() => _busyText = 'Menyiapkan foto... $d/${todo.length}');
      });
      if (mounted) setState(() => _busyText = 'Membuat dokumen...');
      bytes = await _buildPdf();
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
            final cell = _cells[_cellId(f)];
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
          return Center(
            child: Container(
              width: _pageW * scale,
              height: _pageH * scale,
              decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(blurRadius: 6, color: Colors.black26)]),
              child: Stack(children: cells),
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
        _row('Tinggi nama berkas', _intDropdown(_fontPt, const [8, 9, 10, 12, 14, 16, 18, 20], (v) => '$v pt', (v) {
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
