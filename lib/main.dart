import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
/// - [lasso]: draw a freeform loop around nodes to select them, then Wire Section.
/// - [measure]: click two nodes to read the straight-line distance between them.
enum _InteractMode { pickStart, manual, section, lasso, measure, addNode, lassoErase }

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
  ui.Image? _bgImage; // raster backdrop (PNG/JPEG) for manual node placement
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
  int _measureA = -1; // first node picked in measure mode
  int _measureB = -1; // second node picked in measure mode
  bool _showWires = true; // draw wire segments between numbered nodes
  Offset? _dragStart; // section rubber-band, local widget coords
  Offset? _dragCurrent;
  final List<Offset> _lassoPoints = []; // freeform lasso path, local widget coords
  Offset? _hoverLocal; // last mouse position over the canvas, for keyboard actions
  // View transform (screen = scene * _viewScale + _viewOffset). Reset to fit when a
  // model loads; the mouse wheel zooms toward the cursor.
  double _viewScale = 1;
  Offset _viewOffset = Offset.zero;
  double _fitScale = 1; // scale of the fit-to-window view, for clamping zoom
  bool _needFit = true;
  bool _panning = false; // a Shift-drag pan is in progress
  bool _middlePanning = false; // a middle-button drag pan is in progress
  bool _unwiring = false; // a Ctrl-drag unwire is in progress

  // Hold Shift while dragging to pan the view (instead of selecting/wiring).
  bool get _panModifier => HardwareKeyboard.instance.isShiftPressed;
  // Hold Ctrl to unwire nodes by clicking or dragging across them.
  bool get _unwireModifier => HardwareKeyboard.instance.isControlPressed;
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
    _bgImage = null;
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
    _bgImage = null;
    _model.name =
        file.name.replaceAll(RegExp(r'\.svg$', caseSensitive: false), '');
    _detect();
  }

  // Open a PNG/JPEG as a backdrop, then place nodes on it by hand (Add node mode)
  // or auto-detect bright/dark spots. Image pixels map straight to scene units.
  Future<void> _openImage() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open image',
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) return;
    final ui.Image image;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      image = (await codec.getNextFrame()).image;
    } catch (_) {
      setState(() => _status = 'Could not decode that image.');
      return;
    }
    setState(() {
      _bgImage = image;
      _dxf = null;
      _svgCircles = [];
      _model = Model()
        ..name = file.name
            .replaceAll(RegExp(r'\.(png|jpe?g)$', caseSensitive: false), '');
      _startIndex = -1;
      _selection.clear();
      _strokeAdded.clear();
      _measureA = -1;
      _measureB = -1;
      _mode = _InteractMode.addNode;
      _needFit = true;
      _status = 'Image loaded (${image.width}×${image.height}). Click to add '
          'nodes, Ctrl-click to remove, or use Auto-detect.';
    });
  }

  // Scan the loaded image for bright (or dark) blobs and drop a node at the
  // centroid of each, on top of any nodes already placed.
  Future<void> _autoDetectSpots({required bool bright}) async {
    final image = _bgImage;
    if (image == null) return;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      setState(() => _status = 'Could not read image pixels.');
      return;
    }
    final w = image.width, h = image.height;
    final px = data.buffer.asUint8List();
    // Threshold on luminance; "bright" keeps light spots, otherwise dark spots.
    final mask = Uint8List(w * h);
    for (var i = 0; i < w * h; i++) {
      final o = i * 4;
      final lum = 0.299 * px[o] + 0.587 * px[o + 1] + 0.114 * px[o + 2];
      final hit = bright ? lum > 180 : lum < 75;
      mask[i] = hit ? 1 : 0;
    }
    // Flood-fill connected components, taking each as one candidate spot.
    final visited = Uint8List(w * h);
    final spots = <Offset>[];
    final minArea = math.max(4, (w * h) ~/ 200000); // ignore specks
    final stack = <int>[];
    for (var start = 0; start < w * h; start++) {
      if (mask[start] == 0 || visited[start] == 1) continue;
      stack
        ..clear()
        ..add(start);
      visited[start] = 1;
      var area = 0;
      var sx = 0.0, sy = 0.0;
      while (stack.isNotEmpty) {
        final p = stack.removeLast();
        final cx = p % w, cy = p ~/ w;
        area++;
        sx += cx;
        sy += cy;
        for (final n in [p - 1, p + 1, p - w, p + w]) {
          if (n < 0 || n >= w * h) continue;
          // Skip horizontal wrap-around at row edges.
          if ((n == p - 1 && cx == 0) || (n == p + 1 && cx == w - 1)) continue;
          if (mask[n] == 1 && visited[n] == 0) {
            visited[n] = 1;
            stack.add(n);
          }
        }
      }
      if (area >= minArea) spots.add(Offset(sx / area, sy / area));
    }
    for (final s in spots) {
      // Image pixel (sx, sy) -> scene (sx, sy) -> node (x, -y); see _addNodeAt.
      _model.addNode(Node(s.dx, -s.dy, radius: 5));
    }
    setState(() {
      _needFit = _model.nodeCount == spots.length; // first nodes: fit the view
      _status = spots.isEmpty
          ? 'No ${bright ? "bright" : "dark"} spots found.'
          : 'Detected ${spots.length} ${bright ? "bright" : "dark"} spot(s). '
              'Total ${_model.nodeCount} node(s).';
    });
  }

  // Detect DXF holes, returning (mmPerUnit, holes, unitCode). For a unitless file
  // on "Auto" the units are unknown, so try the common candidates and use whichever
  // finds the most holes near the target diameter.
  (double, List<Hole>, int) _dxfDetect(double holeDiaMm) {
    if (_units == 0 && (_dxf?.insUnits ?? 0) == 0) {
      var bestCode = 4; // mm (1 unit = 1 mm)
      var best = findHoles(_dxf!, holeDiaMm, 0.5);
      for (final c in [1, 5, 2]) {
        // inches, cm, feet
        final mpu = millimetersPerUnit(c);
        final h = findHoles(_dxf!, holeDiaMm / mpu, 0.5 / mpu);
        if (h.length > best.length) {
          best = h;
          bestCode = c;
        }
      }
      final mpu = millimetersPerUnit(bestCode);
      return (mpu <= 0 ? 1.0 : mpu, best, bestCode);
    }
    var mpu = millimetersPerUnit(_effectiveInsUnits());
    if (mpu <= 0) mpu = 1.0;
    return (mpu, findHoles(_dxf!, holeDiaMm / mpu, 0.5 / mpu), _effectiveInsUnits());
  }

  String _unitCodeName(int c) => switch (c) {
        1 => 'inches',
        2 => 'feet',
        4 => 'mm',
        5 => 'cm',
        6 => 'm',
        _ => 'units',
      };

  void _detect() {
    // Build hole centres (in node-mm) from whichever source is loaded.
    final centres = <Node>[];
    var unitNote = '';
    if (_dxf != null) {
      final (mmPerUnit, holes, unitCode) = _dxfDetect(_holeDiaMm);
      if (_units == 0 && _dxf!.insUnits == 0 && holes.isNotEmpty) {
        unitNote = ' (auto: ${_unitCodeName(unitCode)})';
      }
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
      _needFit = true; // fit the freshly detected model to the view
      _status = model.nodeCount == 0
          ? 'No ~${_holeDiaMm.round()}mm holes found. '
              'If the file is unitless, try the Units dropdown.'
          : 'Found ${model.nodeCount} holes (~${_holeDiaMm.round()}mm)$unitNote. '
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

  // Remove the wiring of a single node (the one under the cursor), closing the
  // numbering gap so the run stays continuous. Bound to Delete/Backspace.
  void _removeWireAt(Offset? local, _NodePainter painter) {
    if (local == null) return;
    final scene = painter.toScene(local);
    if (scene == null) return;
    final idx = _nearestIndex(scene);
    if (idx < 0) {
      setState(() => _status = 'Nothing to unwire there.');
      return;
    }
    if (!_unwireIndex(idx)) {
      setState(() => _status = 'That node is not wired.');
    }
  }

  // Unwire one node, closing the numbering gap. Returns false if it wasn't wired.
  bool _unwireIndex(int idx) {
    if (idx < 0 || idx >= _model.nodeCount) return false;
    final num = _model.nodes[idx].nodeNumber;
    if (!_model.removeFromWiring(idx)) return false;
    _strokeAdded.remove(idx);
    setState(() => _status = 'Removed node $num from the wiring.');
    return true;
  }

  // Unwire the node under a scene point, but only if the point actually lands on
  // it — so a Ctrl-click/drag across empty space doesn't unwire a distant node.
  void _unwireSceneHit(Offset scene) {
    final idx = _nearestIndex(scene);
    if (idx < 0) return;
    final n = _model.nodes[idx];
    final dx = n.x - scene.dx, dy = -n.y - scene.dy;
    final hitR = math.max(n.radius, 8.0);
    if (dx * dx + dy * dy <= hitR * hitR) _unwireIndex(idx);
  }

  // Add-node mode: click empty space to drop a node; click an existing node
  // (within its radius) to delete it instead.
  void _addOrRemoveNodeAt(Offset scene) {
    final idx = _nearestIndex(scene);
    if (idx >= 0) {
      final n = _model.nodes[idx];
      final dx = n.x - scene.dx, dy = -n.y - scene.dy;
      final hitR = math.max(n.radius, 6.0);
      if (dx * dx + dy * dy <= hitR * hitR) {
        _model.removeNode(idx);
        setState(() {
          if (_startIndex == idx) _startIndex = -1;
          _status = 'Removed a node. ${_model.nodeCount} left.';
        });
        return;
      }
    }
    // Scene (sx, sy) -> node (x, -y) so the marker lands under the cursor.
    _model.addNode(Node(scene.dx, -scene.dy, radius: 5));
    setState(() => _status = 'Added a node. ${_model.nodeCount} total.');
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

  // Pick a node in measure mode: first click sets A, second sets B and reports
  // the distance, a third click starts a fresh measurement from the new node.
  void _measurePick(int idx) {
    if (idx < 0 || idx >= _model.nodeCount) return;
    setState(() {
      if (_measureA < 0 || _measureB >= 0) {
        _measureA = idx;
        _measureB = -1;
        _status = 'Measure: pick a second node.';
      } else if (idx == _measureA) {
        _status = 'Measure: pick a different second node.';
      } else {
        _measureB = idx;
        final a = _model.nodes[_measureA];
        final b = _model.nodes[idx];
        final dx = a.x - b.x;
        final dy = a.y - b.y;
        final dist = math.sqrt(dx * dx + dy * dy);
        _status = 'Distance: ${dist.toStringAsFixed(1)} mm '
            '(Δx ${dx.abs().toStringAsFixed(1)}, Δy ${dy.abs().toStringAsFixed(1)}).';
      }
    });
  }

  String _modeName(_InteractMode m) => switch (m) {
        _InteractMode.pickStart => 'Pick start',
        _InteractMode.manual => 'Manual wire',
        _InteractMode.section => 'Select section',
        _InteractMode.lasso => 'Lasso select',
        _InteractMode.measure => 'Measure',
        _InteractMode.addNode => 'Add node',
        _InteractMode.lassoErase => 'Lasso erase',
      };

  // Modes that build a node selection for Wire Section.
  bool get _isSelectMode =>
      _mode == _InteractMode.section || _mode == _InteractMode.lasso;

  // Ray-casting point-in-polygon test (all coordinates in the same space).
  static bool _pointInPolygon(Offset p, List<Offset> poly) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final xi = poly[i].dx, yi = poly[i].dy;
      final xj = poly[j].dx, yj = poly[j].dy;
      if (((yi > p.dy) != (yj > p.dy)) &&
          (p.dx < (xj - xi) * (p.dy - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
    }
    return inside;
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
          OutlinedButton.icon(
              onPressed: _openSvg,
              icon: const Icon(Icons.image_outlined),
              label: const Text('Open SVG')),
          OutlinedButton.icon(
              onPressed: _openImage,
              icon: const Icon(Icons.photo),
              label: const Text('Open Image')),
          _numberField('Hole Ø (mm)', _holeDiaCtrl, onSubmit: _detect),
          _unitsDropdown(),
          _numberField('Wire gap (mm)', _wireGapCtrl),
          _strategyDropdown(),
          _modeDropdown(),
          _showWiresCheckbox(),
          OutlinedButton.icon(
              onPressed:
                  _bgImage == null ? null : () => _autoDetectSpots(bright: true),
              icon: const Icon(Icons.lightbulb_outline),
              label: const Text('Detect bright')),
          OutlinedButton.icon(
              onPressed:
                  _bgImage == null ? null : () => _autoDetectSpots(bright: false),
              icon: const Icon(Icons.lightbulb),
              label: const Text('Detect dark')),
          FilledButton.icon(
              onPressed: _model.nodeCount == 0 ? null : _autoWire,
              icon: const Icon(Icons.timeline),
              label: const Text('Auto Wire')),
          FilledButton.icon(
              onPressed: (_isSelectMode && _selection.isNotEmpty) ? _wireSection : null,
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
          DropdownMenuItem(
              value: _InteractMode.lasso, child: Text('Lasso select')),
          DropdownMenuItem(
              value: _InteractMode.measure, child: Text('Measure')),
          DropdownMenuItem(
              value: _InteractMode.addNode, child: Text('Add node')),
          DropdownMenuItem(
              value: _InteractMode.lassoErase, child: Text('Lasso erase')),
        ],
        onChanged: (v) => setState(() {
          _mode = v ?? _mode;
          _strokeAdded.clear();
          _dragStart = null;
          _dragCurrent = null;
          _lassoPoints.clear();
          _measureA = -1;
          _measureB = -1;
          if (!_isSelectMode) _selection.clear();
          _status = switch (_mode) {
            _InteractMode.measure =>
              'Measure: click a node, then a second to read the distance.',
            _InteractMode.addNode =>
              'Add node: click to place, click a node to remove it.',
            _InteractMode.lassoErase =>
              'Lasso erase: draw a loop around nodes to delete them.',
            _ => '${_modeName(_mode)} mode.',
          };
        }),
      ),
    );
  }

  Widget _showWiresCheckbox() {
    return InkWell(
      onTap: () => setState(() => _showWires = !_showWires),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: _showWires,
            onChanged: (v) => setState(() => _showWires = v ?? _showWires),
          ),
          const Text('Show wires'),
        ],
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

  // Fit-to-window transform (screen = scene * scale + offset) for the current
  // model and/or backdrop image.
  ({double scale, Offset offset}) _computeFit(Size size) {
    if (_model.nodeCount == 0 && _bgImage == null) {
      return (scale: 1, offset: Offset.zero);
    }
    double? minx, maxx, miny, maxy;
    void include(double x, double sy) {
      minx = minx == null ? x : math.min(minx!, x);
      maxx = maxx == null ? x : math.max(maxx!, x);
      miny = miny == null ? sy : math.min(miny!, sy);
      maxy = maxy == null ? sy : math.max(maxy!, sy);
    }

    for (final n in _model.nodes) {
      include(n.x, -n.y);
    }
    // The image is drawn in scene rect (0,0)-(width,height); include its corners.
    if (_bgImage != null) {
      include(0, 0);
      include(_bgImage!.width.toDouble(), _bgImage!.height.toDouble());
    }
    const pad = 24.0;
    final spanX = (maxx! - minx!).abs() < 1e-6 ? 1.0 : maxx! - minx!;
    final spanY = (maxy! - miny!).abs() < 1e-6 ? 1.0 : maxy! - miny!;
    final sx = (size.width - pad * 2) / spanX;
    final sy = (size.height - pad * 2) / spanY;
    final s = sx < sy ? sx : sy;
    return (scale: s, offset: Offset(pad - minx! * s, pad - miny! * s));
  }

  Widget _canvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        // Fit the model (or backdrop image) to the view once after it loads; the
        // wheel then zooms.
        if (_needFit &&
            (_model.nodeCount > 0 || _bgImage != null) &&
            size.width > 0 &&
            size.height > 0) {
          final fit = _computeFit(size);
          _viewScale = fit.scale;
          _viewOffset = fit.offset;
          _fitScale = fit.scale;
          _needFit = false;
        }
        final painter = _NodePainter(
          _model,
          _mode == _InteractMode.pickStart ? _startIndex : -1,
          _selection,
          _dragStart,
          _dragCurrent,
          _lassoPoints,
          _mode == _InteractMode.measure ? _measureA : -1,
          _mode == _InteractMode.measure ? _measureB : -1,
          _wireGapMm,
          _showWires,
          _viewScale,
          _viewOffset,
          _bgImage,
          _mode == _InteractMode.lassoErase,
        );

        void onTap(Offset local) {
          final scene = painter.toScene(local);
          if (scene == null) return;
          if (_unwireModifier) {
            _unwireSceneHit(scene); // Ctrl-click unwires, whatever the mode
            return;
          }
          if (_mode == _InteractMode.addNode) {
            _addOrRemoveNodeAt(scene);
            return;
          }
          final idx = _nearestIndex(scene);
          if (idx < 0) return;
          switch (_mode) {
            case _InteractMode.pickStart:
              setState(() => _startIndex = idx);
            case _InteractMode.manual:
              _manualAdd(idx);
            case _InteractMode.section:
            case _InteractMode.lasso:
              setState(() => _selection.contains(idx)
                  ? _selection.remove(idx)
                  : _selection.add(idx));
            case _InteractMode.measure:
              _measurePick(idx);
            case _InteractMode.addNode:
              break; // handled above
            case _InteractMode.lassoErase:
              break; // erasing happens on the drag, not a tap
          }
        }

        return Focus(
          autofocus: true,
          // Delete / Backspace: remove the wiring of the node under the cursor.
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent &&
                (e.logicalKey == LogicalKeyboardKey.delete ||
                    e.logicalKey == LogicalKeyboardKey.backspace)) {
              _removeWireAt(_hoverLocal, painter);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Listener(
          // Mouse wheel: zoom in/out toward the cursor.
          onPointerSignal: (e) {
            if (e is PointerScrollEvent && _viewScale > 0) {
              final f = e.localPosition;
              final m = math.pow(1.0015, -e.scrollDelta.dy).toDouble();
              final ns = (_viewScale * m).clamp(_fitScale * 0.1, _fitScale * 50.0);
              final am = ns / _viewScale; // actual multiplier after clamping
              setState(() {
                _viewScale = ns;
                _viewOffset = f - (f - _viewOffset) * am;
              });
            }
          },
          // Middle-button drag: pan the view (the gesture detector below only
          // handles the primary button, so middle drags come through here).
          onPointerDown: (e) {
            if ((e.buttons & kMiddleMouseButton) != 0) _middlePanning = true;
          },
          onPointerMove: (e) {
            _hoverLocal = e.localPosition;
            if (_middlePanning) setState(() => _viewOffset += e.delta);
          },
          // Track the cursor so keyboard actions know which node it's over.
          onPointerHover: (e) => _hoverLocal = e.localPosition,
          onPointerUp: (_) => _middlePanning = false,
          onPointerCancel: (_) => _middlePanning = false,
          child: GestureDetector(
          onTapUp: (d) => onTap(d.localPosition),
          onSecondaryTapUp: (_) {
            if (_mode == _InteractMode.manual) _undoLast();
          },
          onPanStart: (d) {
            if (_unwireModifier) {
              _unwiring = true; // Ctrl-drag: unwire nodes along the path
              final scene = painter.toScene(d.localPosition);
              if (scene != null) _unwireSceneHit(scene);
            } else if (_panModifier) {
              _panning = true; // Shift-drag: pan the view
            } else if (_mode == _InteractMode.section) {
              setState(() {
                _dragStart = d.localPosition;
                _dragCurrent = d.localPosition;
              });
            } else if (_mode == _InteractMode.lasso ||
                _mode == _InteractMode.lassoErase) {
              setState(() {
                _lassoPoints
                  ..clear()
                  ..add(d.localPosition);
              });
            } else if (_mode == _InteractMode.manual) {
              _strokeAdded.clear();
              final scene = painter.toScene(d.localPosition);
              if (scene != null) _manualAdd(_nearestIndex(scene));
            }
          },
          onPanUpdate: (d) {
            if (_unwiring) {
              final scene = painter.toScene(d.localPosition);
              if (scene != null) _unwireSceneHit(scene);
            } else if (_panning) {
              setState(() => _viewOffset += d.delta); // pan with the drag
            } else if (_mode == _InteractMode.section) {
              setState(() => _dragCurrent = d.localPosition);
            } else if (_mode == _InteractMode.lasso ||
                _mode == _InteractMode.lassoErase) {
              setState(() => _lassoPoints.add(d.localPosition));
            } else if (_mode == _InteractMode.manual) {
              final scene = painter.toScene(d.localPosition);
              if (scene != null) {
                final idx = _nearestIndex(scene);
                if (idx >= 0 && !_strokeAdded.contains(idx)) _manualAdd(idx);
              }
            }
          },
          onPanEnd: (_) {
            if (_unwiring) {
              _unwiring = false;
            } else if (_panning) {
              _panning = false;
            } else if (_mode == _InteractMode.section &&
                _dragStart != null &&
                _dragCurrent != null) {
              final a = painter.toScene(_dragStart!);
              final b = painter.toScene(_dragCurrent!);
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
            } else if (_mode == _InteractMode.lasso && _lassoPoints.length >= 3) {
              // Convert the freeform path to scene coords and select enclosed nodes.
              final poly = <Offset>[];
              for (final p in _lassoPoints) {
                final s = painter.toScene(p);
                if (s != null) poly.add(s);
              }
              setState(() {
                if (poly.length >= 3) {
                  _selection.clear();
                  for (var i = 0; i < _model.nodeCount; i++) {
                    final n = _model.nodes[i];
                    if (_pointInPolygon(Offset(n.x, -n.y), poly)) _selection.add(i);
                  }
                  _status = '${_selection.length} node(s) selected.';
                }
                _lassoPoints.clear();
              });
            } else if (_mode == _InteractMode.lassoErase &&
                _lassoPoints.length >= 3) {
              // Convert the freeform path to scene coords and delete the nodes it
              // encloses (their wiring closes up as each is removed).
              final poly = <Offset>[];
              for (final p in _lassoPoints) {
                final s = painter.toScene(p);
                if (s != null) poly.add(s);
              }
              setState(() {
                var removed = 0;
                if (poly.length >= 3) {
                  // Delete from the end so earlier indices stay valid.
                  for (var i = _model.nodeCount - 1; i >= 0; i--) {
                    final n = _model.nodes[i];
                    if (_pointInPolygon(Offset(n.x, -n.y), poly)) {
                      _model.removeNode(i);
                      removed++;
                    }
                  }
                }
                if (removed > 0) {
                  // Indices shifted, so any cached references are now stale.
                  _startIndex = -1;
                  _selection.clear();
                  _measureA = -1;
                  _measureB = -1;
                }
                _status = 'Erased $removed node(s).';
                _lassoPoints.clear();
              });
            } else {
              setState(() => _lassoPoints.clear());
            }
          },
          child: CustomPaint(size: size, painter: painter),
          ),
          ),
        );
      },
    );
  }
}

class _NodePainter extends CustomPainter {
  _NodePainter(
      this.model, this.startIndex, this.selection, this.dragStart, this.dragCurrent,
      this.lassoPoints, this.measureA, this.measureB, this.wireGapMm,
      this.showWires, this.scale, this.offset, this.image, this.eraseLasso);
  final Model model;
  final int startIndex;
  final Set<int> selection;
  final Offset? dragStart; // section rubber-band, local widget coords
  final Offset? dragCurrent;
  final List<Offset> lassoPoints; // freeform lasso path, local widget coords
  final int measureA; // measure-mode endpoints (-1 when unset)
  final int measureB;
  final double wireGapMm; // segments longer than this are drawn red
  final bool showWires; // whether to draw the wire run between numbered nodes
  final double scale; // screen = scene * scale + offset
  final Offset offset;
  final ui.Image? image; // backdrop drawn in scene rect (0,0)-(width,height)
  final bool eraseLasso; // draw the freeform lasso in red (delete) vs orange

  // Screen position of a node's marker centre.
  Offset _screen(int i) {
    final n = model.nodes[i];
    return Offset(n.x * scale + offset.dx, (-n.y) * scale + offset.dy);
  }

  Offset? toScene(Offset local) {
    if (scale == 0) return null;
    return Offset((local.dx - offset.dx) / scale, (local.dy - offset.dy) / scale);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (scale == 0) return;

    // Backdrop image, drawn in scene rect (0,0)-(width,height).
    if (image != null) {
      final src = Rect.fromLTWH(
          0, 0, image!.width.toDouble(), image!.height.toDouble());
      final dst = Rect.fromLTWH(
          offset.dx, offset.dy, image!.width * scale, image!.height * scale);
      canvas.drawImageRect(image!, src, dst, Paint());
    }

    if (model.nodeCount == 0) return;

    // Wire run: connect consecutively numbered nodes. A segment longer than the
    // wire gap is drawn red so over-length hops stand out; others are blue.
    final byNumber = <int, int>{}; // nodeNumber -> node index
    for (var i = 0; i < model.nodeCount; i++) {
      final num = model.nodes[i].nodeNumber;
      if (num > 0) byNumber[num] = i;
    }
    if (showWires && byNumber.length > 1) {
      final maxNum =
          byNumber.keys.reduce((a, b) => a > b ? a : b);
      final okPen = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFF5AAAFF);
      final overPen = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = const Color(0xFFEF3030);
      for (var num = 1; num < maxNum; num++) {
        final ai = byNumber[num];
        final bi = byNumber[num + 1];
        if (ai == null || bi == null) continue; // skip gaps in the numbering
        final a = model.nodes[ai];
        final b = model.nodes[bi];
        final len =
            math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
        canvas.drawLine(
            _screen(ai), _screen(bi), len > wireGapMm ? overPen : okPen);
      }
    }

    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.black54;
    for (var i = 0; i < model.nodeCount; i++) {
      final n = model.nodes[i];
      final cx = n.x * scale + offset.dx;
      final cy = (-n.y) * scale + offset.dy;
      final r = (n.radius * scale).clamp(2.0, 1000.0);

      Color fill = Colors.amber;
      if (n.isWired) fill = const Color(0xFF5AAAFF);
      if (i == startIndex) fill = const Color(0xFF28C850);
      if (selection.contains(i)) fill = const Color(0xFFFF9628); // section selection
      if (i == measureA || i == measureB) fill = const Color(0xFFE040FB); // measure

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

    // Measure line + distance label between the two picked endpoints.
    if (measureA >= 0 &&
        measureB >= 0 &&
        measureA < model.nodeCount &&
        measureB < model.nodeCount) {
      final pa = _screen(measureA);
      final pb = _screen(measureB);
      canvas.drawLine(
          pa,
          pb,
          Paint()
            ..color = const Color(0xFFE040FB)
            ..strokeWidth = 1.5);
      final a = model.nodes[measureA];
      final b = model.nodes[measureB];
      final dist = math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
      final tp = TextPainter(
        text: TextSpan(
            text: '${dist.toStringAsFixed(1)} mm',
            style: const TextStyle(
                color: Color(0xFFC51FD6),
                fontSize: 12,
                fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      final mid = (pa + pb) / 2;
      tp.paint(canvas, mid - Offset(tp.width / 2, tp.height + 2));
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

    // Live freeform lasso path (drawn directly in widget coords). Red while
    // erasing nodes, orange while selecting.
    if (lassoPoints.length >= 2) {
      final fillCol = eraseLasso ? const Color(0x28EF3030) : const Color(0x28FF9628);
      final lineCol = eraseLasso ? const Color(0xFFEF3030) : const Color(0xFFFF9628);
      final path = Path()..addPolygon(lassoPoints, true);
      canvas.drawPath(path, Paint()..color = fillCol);
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = lineCol);
    }
  }

  // The selection set is mutated in place and the drag rect changes continuously,
  // so repaint whenever the widget rebuilds (which only happens on setState).
  @override
  bool shouldRepaint(covariant _NodePainter old) => true;
}
