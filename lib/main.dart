import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'src/auto_wire.dart';
import 'src/dxf_data.dart';
import 'src/dxf_reader.dart';
import 'src/hole_finder.dart';
import 'src/model.dart';
import 'src/saver.dart';
import 'src/svg_reader.dart';

/// Canvas interaction modes.
/// - [pickStart]: click a node to set the whole-model Auto Wire start.
/// - [manual]: click or drag across nodes to wire them by hand.
/// - [section]: drag a box (or click nodes) to select a group, then Wire Section.
enum _InteractMode { pickStart, manual, section }

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
  List<SvgCircle> _svgCircles = []; // active when loaded from SVG
  Model _model = Model();
  final _holeDiaCtrl = TextEditingController(text: '12');
  final _wireGapCtrl = TextEditingController(text: '100');
  int _startIndex = -1;
  // Drawing-units override: 0 Auto (file), 1 mm, 2 cm, 3 in, 4 ft, 5 m.
  int _units = 0;
  WireStrategy _strategy = WireStrategy.nearestFirst;
  _InteractMode _mode = _InteractMode.pickStart;
  final Set<int> _selection = {}; // section-mode selected node indices
  final Set<int> _strokeAdded = {}; // nodes added during the current manual drag
  Offset? _dragStart; // section rubber-band, local widget coords
  Offset? _dragCurrent;
  String _status = 'Open a DXF to begin.';

  // Read the fields live so Auto Wire / detect always use what's in the box,
  // even if the user didn't press Enter (matches the Qt spin-box behaviour).
  double get _holeDiaMm => double.tryParse(_holeDiaCtrl.text.trim()) ?? 12.0;
  double get _wireGapMm => double.tryParse(_wireGapCtrl.text.trim()) ?? 100.0;

  @override
  void dispose() {
    _holeDiaCtrl.dispose();
    _wireGapCtrl.dispose();
    super.dispose();
  }

  // The DXF units code to use for conversions: the file's $INSUNITS, unless the
  // Units dropdown overrides it (e.g. for unitless files actually drawn in inches).
  int _effectiveInsUnits() {
    switch (_units) {
      case 1:
        return 4; // mm
      case 2:
        return 5; // cm
      case 3:
        return 1; // inches
      case 4:
        return 2; // feet
      case 5:
        return 6; // meters
      default:
        return _dxf?.insUnits ?? 0;
    }
  }

  double _mmToDrawing(double mm) {
    final f = millimetersPerUnit(_effectiveInsUnits());
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
    _svgCircles = []; // DXF is now the active source
    _model.name =
        file.name.replaceAll(RegExp(r'\.dxf$', caseSensitive: false), '');
    _detect();
  }

  Future<void> _openSvg() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open SVG',
      type: FileType.custom,
      allowedExtensions: ['svg'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;
    final text = utf8.decode(bytes, allowMalformed: true);

    final circles = readSvgCircles(text);
    if (circles.isEmpty) {
      setState(() => _status = 'No <circle>/<ellipse> elements found in the SVG.');
      return;
    }
    _svgCircles = circles;
    _dxf = null; // SVG is now the active source
    _model.name =
        file.name.replaceAll(RegExp(r'\.svg$', caseSensitive: false), '');
    _detect();
  }

  void _detect() {
    // Build hole centres (in node-mm) from whichever source is loaded.
    final centres = <Node>[];
    if (_dxf != null) {
      final holeDia = _mmToDrawing(_holeDiaMm);
      final tol = _mmToDrawing(0.5);
      final holes = findHoles(_dxf!, holeDia, tol);
      var mmPerUnit = millimetersPerUnit(_effectiveInsUnits());
      if (mmPerUnit <= 0) mmPerUnit = 1.0;
      for (final h in holes) {
        centres.add(Node(h.x * mmPerUnit, h.y * mmPerUnit, radius: _holeDiaMm / 2));
      }
    } else if (_svgCircles.isNotEmpty) {
      final targetR = _holeDiaMm / 2;
      for (final c in _svgCircles) {
        if ((c.dia / 2 - targetR).abs() <= 0.5) {
          centres.add(Node(c.x, c.y, radius: _holeDiaMm / 2));
        }
      }
    } else {
      return;
    }

    final model = Model()..name = _model.name;
    for (final c in centres) {
      model.addNode(c);
    }
    setState(() {
      _model = model;
      _startIndex = -1;
      _selection.clear();
      _strokeAdded.clear();
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
    final aw = AutoWire(_model, _wireGapMm, strategy: _strategy)
      ..wireModel(n.x, n.y);
    _model.clearWiring();
    var num = 1;
    for (final idx in aw.indexes) {
      _model.setNodeNumber(idx, num++);
    }
    setState(() {
      _startIndex = start;
      _selection.clear();
      if (aw.worked) {
        _status = 'Wired all ${_model.nodeCount} nodes.';
      } else if (_strategy == WireStrategy.nearestFirst) {
        // Nearest-first can stall in a greedy trap even when a full path exists.
        _status = 'Nearest-first wired ${aw.indexes.length} of '
            '${_model.nodeCount} (it can get stuck from some starts — switch '
            'Method to Warnsdorff, raise the wire gap, or pick another start).';
      } else {
        _status = 'Wired ${aw.indexes.length} of ${_model.nodeCount} '
            '(increase the wire gap or pick another start).';
      }
    });
  }

  void _clearWiring() {
    if (!_model.nodes.any((n) => n.isWired)) return;
    _model.clearWiring();
    setState(() => _status = 'Cleared wiring. Pick a start, then Auto Wire.');
  }

  Future<void> _export() async {
    if (_model.nodeCount == 0) return;
    final xml = _model.toXModel();
    final ok = await saveTextFile(
        '${_model.name.isEmpty ? "model" : _model.name}.xmodel', xml);
    setState(() => _status = ok ? 'Exported .xmodel.' : 'Export cancelled.');
  }

  // Index of the model node nearest a scene point (markers are drawn at (x, -y)).
  int _nearestIndex(Offset scenePt) {
    var best = -1;
    var bestD = double.infinity;
    for (var i = 0; i < _model.nodeCount; i++) {
      final node = _model.nodes[i];
      final dx = node.x - scenePt.dx;
      final dy = -node.y - scenePt.dy;
      final d = dx * dx + dy * dy;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  // Next 1-based wire number (highest existing + 1), so manual picks and wired
  // sections chain into one continuous run.
  int _nextNodeNumber() {
    var maxN = 0;
    for (final n in _model.nodes) {
      if (n.nodeNumber > maxN) maxN = n.nodeNumber;
    }
    return maxN + 1;
  }

  // Append node [idx] to the wire run (manual mode), if not already wired.
  void _manualAdd(int idx) {
    if (idx < 0 || idx >= _model.nodeCount) return;
    final n = _model.nodes[idx];
    if (n.isWired) return;
    _model.setNodeNumber(idx, _nextNodeNumber());
    _strokeAdded.add(idx);
    setState(() => _status = 'Wired node ${n.nodeNumber} (manual).');
  }

  // Clear the highest-numbered node (undo the last manual/section step).
  void _undoLast() {
    var maxN = 0;
    var idx = -1;
    for (var i = 0; i < _model.nodeCount; i++) {
      if (_model.nodes[i].nodeNumber > maxN) {
        maxN = _model.nodes[i].nodeNumber;
        idx = i;
      }
    }
    if (idx < 0) {
      setState(() => _status = 'Nothing to undo.');
      return;
    }
    _model.setNodeNumber(idx, 0);
    _strokeAdded.remove(idx);
    setState(() => _status = 'Removed node $maxN.');
  }

  // Auto-wire the current section selection, numbering on from the highest.
  void _wireSection() {
    final sel = _selection
        .where((i) => i >= 0 && i < _model.nodeCount && !_model.nodes[i].isWired)
        .toList();
    if (sel.isEmpty) {
      setState(() => _status = 'No unwired nodes selected.');
      return;
    }

    // Section start: the selected node nearest the last-wired node, so the run
    // continues smoothly from existing wiring; otherwise the first selected.
    var lastNum = 0;
    var lastIdx = -1;
    for (var i = 0; i < _model.nodeCount; i++) {
      if (_model.nodes[i].nodeNumber > lastNum) {
        lastNum = _model.nodes[i].nodeNumber;
        lastIdx = i;
      }
    }
    var startSel = sel.first;
    if (lastIdx >= 0) {
      var best = -1.0;
      for (final idx in sel) {
        final dx = _model.nodes[idx].x - _model.nodes[lastIdx].x;
        final dy = _model.nodes[idx].y - _model.nodes[lastIdx].y;
        final d = dx * dx + dy * dy;
        if (best < 0 || d < best) {
          best = d;
          startSel = idx;
        }
      }
    }

    // Build a temp model of just the selected nodes; remember the index mapping.
    final sub = Model();
    final realIndex = <int>[];
    for (final idx in sel) {
      final n = _model.nodes[idx];
      sub.addNode(Node(n.x, n.y, radius: n.radius));
      realIndex.add(idx);
    }

    final startNode = _model.nodes[startSel];
    final aw = AutoWire(sub, _wireGapMm, strategy: _strategy)
      ..wireModel(startNode.x, startNode.y);

    var num = _nextNodeNumber();
    for (final subIdx in aw.indexes) {
      if (subIdx >= 0 && subIdx < realIndex.length) {
        _model.setNodeNumber(realIndex[subIdx], num++);
      }
    }

    final wired = aw.indexes.length;
    setState(() {
      _selection.clear();
      _status = wired == sel.length
          ? 'Wired section of $wired node(s).'
          : 'Wired $wired of ${sel.length} selected '
              '(raise the wire gap or try Warnsdorff).';
    });
  }

  String _modeName(_InteractMode m) => switch (m) {
        _InteractMode.pickStart => 'Pick start',
        _InteractMode.manual => 'Manual wire',
        _InteractMode.section => 'Select section',
      };

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
          OutlinedButton.icon(
              onPressed: _openSvg,
              icon: const Icon(Icons.image_outlined),
              label: const Text('Open SVG')),
          _numberField('Hole Ø (mm)', _holeDiaCtrl, onSubmit: _detect),
          _unitsDropdown(),
          _numberField('Wire gap (mm)', _wireGapCtrl),
          _strategyDropdown(),
          _modeDropdown(),
          FilledButton.icon(
              onPressed: _model.nodeCount == 0 ? null : _autoWire,
              icon: const Icon(Icons.timeline),
              label: const Text('Auto Wire')),
          FilledButton.icon(
              onPressed: (_mode == _InteractMode.section && _selection.isNotEmpty)
                  ? _wireSection
                  : null,
              icon: const Icon(Icons.cable),
              label: const Text('Wire Section')),
          OutlinedButton.icon(
              onPressed: _model.nodes.any((n) => n.isWired) ? _undoLast : null,
              icon: const Icon(Icons.undo),
              label: const Text('Undo Last')),
          OutlinedButton.icon(
              onPressed: _model.nodes.any((n) => n.isWired) ? _clearWiring : null,
              icon: const Icon(Icons.clear),
              label: const Text('Clear Wiring')),
          FilledButton.icon(
              onPressed: _model.nodeCount == 0 ? null : _export,
              icon: const Icon(Icons.save_alt),
              label: const Text('Export xModel')),
        ],
      ),
    );
  }

  Widget _unitsDropdown() {
    const labels = [
      'Auto (file)',
      'Millimeters',
      'Centimeters',
      'Inches',
      'Feet',
      'Meters',
    ];
    return SizedBox(
      width: 150,
      child: DropdownButtonFormField<int>(
        initialValue: _units,
        isExpanded: true,
        decoration: const InputDecoration(
            labelText: 'Units',
            isDense: true,
            border: OutlineInputBorder()),
        items: [
          for (var i = 0; i < labels.length; i++)
            DropdownMenuItem(value: i, child: Text(labels[i])),
        ],
        onChanged: (v) {
          setState(() => _units = v ?? _units);
          // Re-interpret the loaded DXF at the new units (_detect calls setState).
          if (_dxf != null) _detect();
        },
      ),
    );
  }

  Widget _modeDropdown() {
    return SizedBox(
      width: 170,
      child: DropdownButtonFormField<_InteractMode>(
        initialValue: _mode,
        isExpanded: true,
        decoration: const InputDecoration(
            labelText: 'Mode',
            isDense: true,
            border: OutlineInputBorder()),
        items: const [
          DropdownMenuItem(
              value: _InteractMode.pickStart, child: Text('Pick start')),
          DropdownMenuItem(
              value: _InteractMode.manual, child: Text('Manual wire')),
          DropdownMenuItem(
              value: _InteractMode.section, child: Text('Select section')),
        ],
        onChanged: (v) => setState(() {
          _mode = v ?? _mode;
          _strokeAdded.clear();
          _dragStart = null;
          _dragCurrent = null;
          if (_mode != _InteractMode.section) _selection.clear();
          _status = '${_modeName(_mode)} mode.';
        }),
      ),
    );
  }

  Widget _strategyDropdown() {
    return SizedBox(
      width: 170,
      child: DropdownButtonFormField<WireStrategy>(
        initialValue: _strategy,
        isExpanded: true,
        decoration: const InputDecoration(
            labelText: 'Method',
            isDense: true,
            border: OutlineInputBorder()),
        items: const [
          DropdownMenuItem(
              value: WireStrategy.nearestFirst,
              child: Text('Nearest-first')),
          DropdownMenuItem(
              value: WireStrategy.warnsdorff, child: Text('Warnsdorff')),
        ],
        onChanged: (v) => setState(() => _strategy = v ?? _strategy),
      ),
    );
  }

  Widget _numberField(String label, TextEditingController controller,
      {VoidCallback? onSubmit}) {
    return SizedBox(
      width: 130,
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder()),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onFieldSubmitted: (_) => onSubmit?.call(),
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
        final size = constraints.biggest;
        final painter = _NodePainter(
          _model,
          _mode == _InteractMode.pickStart ? _startIndex : -1,
          _selection,
          _dragStart,
          _dragCurrent,
        );

        void onTap(Offset local) {
          final scene = painter.toScene(local, size);
          if (scene == null) return;
          final idx = _nearestIndex(scene);
          if (idx < 0) return;
          switch (_mode) {
            case _InteractMode.pickStart:
              setState(() => _startIndex = idx);
            case _InteractMode.manual:
              _manualAdd(idx);
            case _InteractMode.section:
              setState(() => _selection.contains(idx)
                  ? _selection.remove(idx)
                  : _selection.add(idx));
          }
        }

        return GestureDetector(
          onTapUp: (d) => onTap(d.localPosition),
          onSecondaryTapUp: (_) {
            if (_mode == _InteractMode.manual) _undoLast();
          },
          onPanStart: (d) {
            if (_mode == _InteractMode.section) {
              setState(() {
                _dragStart = d.localPosition;
                _dragCurrent = d.localPosition;
              });
            } else if (_mode == _InteractMode.manual) {
              _strokeAdded.clear();
              final scene = painter.toScene(d.localPosition, size);
              if (scene != null) _manualAdd(_nearestIndex(scene));
            }
          },
          onPanUpdate: (d) {
            if (_mode == _InteractMode.section) {
              setState(() => _dragCurrent = d.localPosition);
            } else if (_mode == _InteractMode.manual) {
              final scene = painter.toScene(d.localPosition, size);
              if (scene != null) {
                final idx = _nearestIndex(scene);
                if (idx >= 0 && !_strokeAdded.contains(idx)) _manualAdd(idx);
              }
            }
          },
          onPanEnd: (_) {
            if (_mode != _InteractMode.section ||
                _dragStart == null ||
                _dragCurrent == null) {
              return;
            }
            final a = painter.toScene(_dragStart!, size);
            final b = painter.toScene(_dragCurrent!, size);
            setState(() {
              if (a != null && b != null) {
                final rect = Rect.fromPoints(a, b);
                _selection.clear();
                for (var i = 0; i < _model.nodeCount; i++) {
                  final n = _model.nodes[i];
                  if (rect.contains(Offset(n.x, -n.y))) _selection.add(i);
                }
                _status = '${_selection.length} node(s) selected.';
              }
              _dragStart = null;
              _dragCurrent = null;
            });
          },
          child: CustomPaint(size: size, painter: painter),
        );
      },
    );
  }
}

class _NodePainter extends CustomPainter {
  _NodePainter(
      this.model, this.startIndex, this.selection, this.dragStart, this.dragCurrent);
  final Model model;
  final int startIndex;
  final Set<int> selection;
  final Offset? dragStart; // section rubber-band, local widget coords
  final Offset? dragCurrent;

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
      if (selection.contains(i)) fill = const Color(0xFFFF9628); // section selection

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

    // Live section rubber-band (drawn directly in widget coords).
    if (dragStart != null && dragCurrent != null) {
      final rect = Rect.fromPoints(dragStart!, dragCurrent!);
      canvas.drawRect(rect, Paint()..color = const Color(0x28FF9628));
      canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = const Color(0xFFFF9628));
    }
  }

  // The selection set is mutated in place and the drag rect changes continuously,
  // so repaint whenever the widget rebuilds (which only happens on setState).
  @override
  bool shouldRepaint(covariant _NodePainter old) => true;
}
