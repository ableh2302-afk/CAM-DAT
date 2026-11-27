import 'package:flutter/material.dart';

String _normNo(String v) {
  final t = v.trim();
  if (t.isEmpty) return '';
  final n = t.replaceFirst(RegExp(r'^0+'), '');
  return n.isEmpty ? '0' : n;
}

/// "LIST NAMA BARANG": daftar semua item dari Excel + kolom pencarian.
/// Ketuk salah satu item untuk memilihnya sebagai nama barang.
class BarangPicker extends StatefulWidget {
  final Map<String, String> barang;
  final Map<String, List<String>> history;
  final String selectedNo;
  final void Function(String no, String name) onPick;
  final double? height; // null = mengisi sisa ruang (harus di dalam Expanded)

  const BarangPicker({
    super.key,
    required this.barang,
    required this.history,
    required this.selectedNo,
    required this.onPick,
    this.height,
  });

  @override
  State<BarangPicker> createState() => _BarangPickerState();
}

class _BarangPickerState extends State<BarangPicker> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<MapEntry<String, String>> _filtered() {
    final words = _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return widget.barang.entries.toList();
    return widget.barang.entries.where((e) {
      final hay = '${e.key} ${e.value}'.toLowerCase();
      return words.every(hay.contains);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered();
    final selected = _normNo(widget.selectedNo);
    final scheme = Theme.of(context).colorScheme;
    final listBox = Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: items.isEmpty
          ? const Center(child: Text('Tidak ada barang yang cocok.', style: TextStyle(color: Colors.white60)))
          : ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: items.length,
              itemBuilder: (_, i) {
                final e = items[i];
                final isSel = selected.isNotEmpty && _normNo(e.key) == selected;
                final photographed = (widget.history[_normNo(e.key)] ?? const <String>[]).isNotEmpty;
                return InkWell(
                  onTap: () => widget.onPick(e.key, e.value),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    color: isSel ? scheme.primary.withValues(alpha: .22) : null,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          child: FittedBox(child: Padding(padding: const EdgeInsets.all(2), child: Text(e.key, style: const TextStyle(fontSize: 11)))),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            e.value,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5, color: Colors.white, fontWeight: isSel ? FontWeight.w700 : FontWeight.w500),
                          ),
                        ),
                        if (isSel)
                          Icon(Icons.radio_button_checked, color: scheme.primary, size: 20)
                        else if (photographed)
                          const Icon(Icons.check_circle, color: Colors.green, size: 20),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
    return Column(
      mainAxisSize: widget.height == null ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('LIST NAMA BARANG', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: .4)),
            const Spacer(),
            Text(
              _query.trim().isEmpty ? '${widget.barang.length} item' : '${items.length} dari ${widget.barang.length}',
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _search,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Cari NO atau nama barang...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
            border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 8),
        if (widget.height == null) Expanded(child: listBox) else SizedBox(height: widget.height, child: listBox),
      ],
    );
  }
}
