import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'src/auto_wire.dart';
import 'src/dxf_data.dart';
import 'src/dxf_reader.dart';
import 'src/hole_finder.dart';
import 'src/model.dart';
import 'src/saver.dart';

void main() => runApp(const XModelGenApp());

class XModelGenApp extends StatelessWidget {
  const XModelGenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'xModelGen',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  DxfData? _dxf;
  Model _model = Model();
  double _holeDiaMm = 12.0;
  double _wireGapMm = 100.0;
  int _startIndex = -1;
  String _status = 'Open a DXF to begin.';

  double _mmToDrawing(double mm) {
    final f = _dxf == null ? 0.0 : millimetersPerUnit(_dxf!.insUnits);
    return f <= 0 ? mm : mm / f; // mm -> drawing units
  }

  Future<void> _openDxf() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open DXF',
      type: FileType.custom,
      allowedExtensions: ['dxf'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;
    final text = utf8.decode(bytes, allowMalformed: true);

    _dxf = parseDxf(text);
    _model.name =
        file.name.replaceAll(RegExp(r'\.dxf$', caseSensitive: false), '');
    _detect();
  }

  void _detect() {
    if (_dxf == null) return;
    final holeDia = _mmToDrawing(_holeDiaMm);
    final tol = _mmToDrawing(0.5);
    final holes = findHoles(_dxf!, holeDia, tol);

    var mmPerUnit = millimetersPerUnit(_dxf!.insUnits);
    if (mmPerUnit <= 0) mmPerUnit = 1.0;

    final model = Model()..name = _model.name;
    for (final h in holes) {
      model.addNode(
          Node(h.x * mmPerUnit, h.y * mmPerUnit, radius: _holeDiaMm / 2));
    }
    setState(() {
      _model = model;
      _startIndex = -1;
      _status = model.nodeCount == 0
          ? 'No ~${_holeDiaMm.round()}mm holes found.'
          : 'Found ${model.nodeCount} holes (~${_holeDiaMm.round()}mm). '
              'Click a hole to set the start, then Auto Wire.';
    });
  }

  void _autoWire() {
    if (_model.nodeCount == 0) return;
    final start = _startIndex >= 0 ? _startIndex : 0;
    final n = _model.nodes[start];
    final aw = AutoWire(_model, _wireGapMm)..wireModel(n.x, n.y);
    _model.clearWiring();
    var num = 1;
    for (final idx in aw.indexes) {
      _model.setNodeNumber(idx, num++);
    }
    setState(() {
      _startIndex = start;
      _status = aw.worked
          ? 'Wired all ${_model.nodeCount} nodes.'
          : 'Wired ${aw.indexes.length} of ${_model.nodeCount} '
              '(increase the wire gap or pick another start).';
    });
  }

  Future<void> _export() async {
    if (_model.nodeCount == 0) return;
    final xml = _model.toXModel();
    final ok = await saveTextFile(
        '${_model.name.isEmpty ? "model" : _model.name}.xmodel', xml);
    setState(() => _status = ok ? 'Exported .xmodel.' : 'Export cancelled.');
  }

  void _selectNearest(Offset scenePt) {
    if (_model.nodeCount == 0) return;
    var best = -1;
    var bestD = double.infinity;
    for (var i = 0; i < _model.nodeCount; i++) {
      final node = _model.nodes[i];
      final dx = node.x - scenePt.dx;
      final dy = -node.y - scenePt.dy; // markers drawn at -Y
      final d = dx * dx + dy * dy;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    setState(() => _startIndex = best);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('xModelGen')),
      body: Column(
        children: [
          _toolbar(),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                SizedBox(width: 220, child: _nodeList()),
                const VerticalDivider(width: 1),
                Expanded(child: _canvas()),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Align(
                alignment: Alignment.centerLeft, child: Text(_status)),
          ),
        ],
      ),
    );
  }

  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
              onPressed: _openDxf,
              icon: const Icon(Icons.folder_open),
              label: const Text('Open DXF')),
          _numberField('Hole Ø (mm)', _holeDiaMm, (v) {
            _holeDiaMm = v;
            _detect();
          }),
          _numberField('Wire gap (mm)', _wireGapMm,
              (v) => setState(() => _wireGapMm = v)),
          FilledButton.icon(
              onPressed: _model.nodeCount == 0 ? null : _autoWire,
              icon: const Icon(Icons.timeline),
              label: const Text('Auto Wire')),
          FilledButton.icon(
              onPressed: _model.nodeCount == 0 ? null : _export,
              icon: const Icon(Icons.save_alt),
              label: const Text('Export xModel')),
        ],
      ),
    );
  }

  Widget _numberField(
      String label, double value, ValueChanged<double> onChanged) {
    return SizedBox(
      width: 130,
      child: TextFormField(
        initialValue: value.toString(),
        decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder()),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onFieldSubmitted: (s) {
          final v = double.tryParse(s);
          if (v != null && v > 0) onChanged(v);
        },
      ),
    );
  }

  Widget _nodeList() {
    return ListView.builder(
      itemCount: _model.nodeCount,
      itemBuilder: (_, i) {
        final n = _model.nodes[i];
        return Container(
          color: i == _startIndex
              ? Colors.green.withValues(alpha: 0.2)
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Text(n.text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        );
      },
    );
  }

  Widget _canvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = _NodePainter(_model, _startIndex);
        return GestureDetector(
          onTapDown: (d) {
            final scene =
                painter.toScene(d.localPosition, constraints.biggest);
            if (scene != null) _selectNearest(scene);
          },
          child: CustomPaint(size: constraints.biggest, painter: painter),
        );
      },
    );
  }
}

class _NodePainter extends CustomPainter {
  _NodePainter(this.model, this.startIndex);
  final Model model;
  final int startIndex;

  double _scale = 1;
  double _ox = 0;
  double _oy = 0;
  bool _ready = false;

  void _computeTransform(Size size) {
    if (model.nodeCount == 0) {
      _ready = false;
      return;
    }
    var minx = model.nodes.first.x, maxx = minx;
    var miny = -model.nodes.first.y, maxy = miny;
    for (final n in model.nodes) {
      minx = minx < n.x ? minx : n.x;
      maxx = maxx > n.x ? maxx : n.x;
      final sy = -n.y;
      miny = miny < sy ? miny : sy;
      maxy = maxy > sy ? maxy : sy;
    }
    const pad = 24.0;
    final spanX = (maxx - minx).abs() < 1e-6 ? 1.0 : maxx - minx;
    final spanY = (maxy - miny).abs() < 1e-6 ? 1.0 : maxy - miny;
    final sx = (size.width - pad * 2) / spanX;
    final sy = (size.height - pad * 2) / spanY;
    _scale = sx < sy ? sx : sy;
    _ox = pad - minx * _scale;
    _oy = pad - miny * _scale;
    _ready = true;
  }

  Offset? toScene(Offset local, Size size) {
    _computeTransform(size);
    if (!_ready) return null;
    return Offset((local.dx - _ox) / _scale, (local.dy - _oy) / _scale);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _computeTransform(size);
    if (!_ready) return;

    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.black54;
    for (var i = 0; i < model.nodeCount; i++) {
      final n = model.nodes[i];
      final cx = n.x * _scale + _ox;
      final cy = (-n.y) * _scale + _oy;
      final r = (n.radius * _scale).clamp(2.0, 1000.0);

      Color fill = Colors.amber;
      if (n.isWired) fill = const Color(0xFF5AAAFF);
      if (i == startIndex) fill = const Color(0xFF28C850);

      canvas.drawCircle(Offset(cx, cy), r, Paint()..color = fill);
      canvas.drawCircle(Offset(cx, cy), r, pen);

      if (n.isWired) {
        final tp = TextPainter(
          text: TextSpan(
              text: '${n.nodeNumber}',
              style: const TextStyle(color: Colors.black, fontSize: 10)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(cx + r, cy - r - tp.height));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _NodePainter old) =>
      old.model != model || old.startIndex != startIndex;
}
