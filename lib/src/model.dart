import 'dart:math' as math;

/// A pixel/hole node. Coordinates are in millimetres.
class Node {
  Node(this.x, this.y, {this.radius = 1.0, this.nodeNumber = 0});

  double x;
  double y;
  double radius;
  int nodeNumber; // wiring order, 0 = unwired

  bool get isWired => nodeNumber != 0;

  String get text => 'Node:$nodeNumber     X:${x.round()}     Y:${y.round()}';
}

double _distance(Node a, Node b) {
  final dx = a.x - b.x;
  final dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}

class Model {
  final List<Node> _nodes = [];
  String name = '';

  List<Node> get nodes => List.unmodifiable(_nodes);
  int get nodeCount => _nodes.length;

  bool _approxEqual(double a, double b, [double eps = 1e-9]) =>
      (a - b).abs() < eps;

  /// Adds a node, skipping exact duplicates (same X/Y).
  void addNode(Node n) {
    final exists = _nodes.any((m) => _approxEqual(m.x, n.x) && _approxEqual(m.y, n.y));
    if (!exists) _nodes.add(n);
  }

  void clearWiring() {
    for (final n in _nodes) {
      n.nodeNumber = 0;
    }
  }

  int findNodeIndex(double x, double y) {
    for (var i = 0; i < _nodes.length; i++) {
      if (_approxEqual(_nodes[i].x, x) && _approxEqual(_nodes[i].y, y)) return i;
    }
    return -1;
  }

  void setNodeNumber(int index, int number) {
    if (index >= 0 && index < _nodes.length) _nodes[index].nodeNumber = number;
  }

  /// Removes a single node from the wire run and closes the gap so the run stays
  /// continuous: every node numbered above the removed one shifts down by one.
  /// Returns true if the node was wired (and so something changed).
  bool removeFromWiring(int index) {
    if (index < 0 || index >= _nodes.length) return false;
    final removed = _nodes[index].nodeNumber;
    if (removed == 0) return false;
    _nodes[index].nodeNumber = 0;
    for (final n in _nodes) {
      if (n.nodeNumber > removed) n.nodeNumber--;
    }
    return true;
  }

  /// Deletes a node entirely (e.g. a manually-placed one), first closing any
  /// wiring gap it leaves so the remaining run stays continuous.
  void removeNode(int index) {
    if (index < 0 || index >= _nodes.length) return;
    removeFromWiring(index);
    _nodes.removeAt(index);
  }

  /// Builds an xLights custom model (.xmodel) XML string from the wired nodes.
  String toXModel() {
    if (_nodes.isEmpty) return '';

    // Grid pitch = median nearest-neighbour spacing, so holes map to adjacent
    // cells rather than a huge millimetre-resolution grid.
    var pitch = 1.0;
    if (_nodes.length > 1) {
      final nearest = <double>[];
      for (var i = 0; i < _nodes.length; i++) {
        var best = double.infinity;
        for (var j = 0; j < _nodes.length; j++) {
          if (i == j) continue;
          final d = _distance(_nodes[i], _nodes[j]);
          if (d > 0 && d < best) best = d;
        }
        if (best.isFinite) nearest.add(best);
      }
      if (nearest.isNotEmpty) {
        nearest.sort();
        pitch = nearest[nearest.length ~/ 2];
      }
    }
    if (!(pitch > 0)) pitch = 1.0;

    var minx = _nodes.first.x, maxx = _nodes.first.x;
    var miny = _nodes.first.y, maxy = _nodes.first.y;
    for (final n in _nodes) {
      minx = math.min(minx, n.x);
      maxx = math.max(maxx, n.x);
      miny = math.min(miny, n.y);
      maxy = math.max(maxy, n.y);
    }

    int gx(double x) => ((x - minx) / pitch).round();
    int gy(double y) => ((y - miny) / pitch).round();

    // Refine the pitch until every hole gets a unique cell.
    bool collides(double p) {
      final seen = <int>{};
      for (final n in _nodes) {
        final cx = ((n.x - minx) / p).round();
        final cy = ((n.y - miny) / p).round();
        if (!seen.add(cx * 100000 + cy)) return true;
      }
      return false;
    }

    for (var attempt = 0; attempt < 12; attempt++) {
      final sx = ((maxx - minx) / pitch).round() + 1;
      final sy = ((maxy - miny) / pitch).round() + 1;
      if (!collides(pitch) || sx * sy > 4000000) break;
      pitch *= 0.5;
    }

    final sizex = gx(maxx) + 1;
    final sizey = gy(maxy) + 1;

    final grid = List.generate(sizey, (_) => List.filled(sizex, -1));
    for (var i = 0; i < _nodes.length; i++) {
      final cx = gx(_nodes[i].x);
      final cy = gy(_nodes[i].y);
      final row = sizey - 1 - cy; // xLights lists the top row first
      final value = _nodes[i].nodeNumber > 0 ? _nodes[i].nodeNumber : i + 1;
      if (row >= 0 && row < sizey && cx >= 0 && cx < sizex) grid[row][cx] = value;
    }

    final rows = grid.map((row) =>
        row.map((c) => c >= 0 ? c.toString() : '').join(',')).join(';');

    return '<?xml version="1.0" encoding="UTF-8"?>\n<custommodel \n'
        'name="$name" '
        'parm1="$sizex" '
        'parm2="$sizey" '
        'Depth="1" '
        'StringType="RGB Nodes" '
        'Transparency="0" '
        'PixelSize="2" '
        'ModelBrightness="" '
        'Antialias="1" '
        'StrandNames="" '
        'NodeNames="" '
        'CustomModel="$rows" '
        'SourceVersion="2025.8" '
        ' >\n</custommodel>';
  }
}
