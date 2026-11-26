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
  final double height;

  const BarangPicker({
    super.key,
    required this.barang,
    required this.history,
    required this.selectedNo,
    required this.onPick,
    this.height = 280,
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
    return Column(
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
        Container(
          height: widget.height,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white24),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: items.isEmpty
              ? const Center(child: Text('Tidak ada barang yang cocok.', style: TextStyle(color: Colors.white60)))
              : ListView.builder(
                  itemCount: items.length,
                  itemExtent: 58,
                  itemBuilder: (_, i) {
                    final e = items[i];
                    final isSel = selected.isNotEmpty && _normNo(e.key) == selected;
                    final photographed = (widget.history[_normNo(e.key)] ?? const <String>[]).isNotEmpty;
                    return ListTile(
                      dense: true,
                      selected: isSel,
                      selectedTileColor: scheme.primary.withValues(alpha: .22),
                      leading: CircleAvatar(
                        radius: 17,
                        child: Text(e.key.length > 3 ? e.key.substring(0, 3) : e.key, style: const TextStyle(fontSize: 11)),
                      ),
                      title: Text(e.value, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text('NO ${e.key}'),
                      trailing: isSel
                          ? Icon(Icons.radio_button_checked, color: scheme.primary)
                          : (photographed ? const Icon(Icons.check_circle, color: Colors.green, size: 20) : null),
                      onTap: () => widget.onPick(e.key, e.value),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
