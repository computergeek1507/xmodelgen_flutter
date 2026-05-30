import 'dart:math' as math;
import 'model.dart';

/// Finds a wiring order by recursive backtracking. Starting from a node it hops
/// to any not-yet-wired node within [wireGap] (so it can skip a near node and
/// pick it up later), using Warnsdorff ordering to find a complete path fast and
/// backtracking on dead ends. Keeps the longest path if none is complete.
class AutoWire {
  AutoWire(this.model, this.wireGap);

  final Model model;
  final double wireGap;

  List<int> indexes = [];
  bool worked = false;

  late List<List<int>> _neighbors;
  int _steps = 0;
  static const int _maxSteps = 5000000;

  void wireModel(double startX, double startY) {
    final nodes = model.nodes;
    final start = model.findNodeIndex(startX, startY);
    if (start == -1) return;
    final n = nodes.length;

    // Precompute within-gap neighbours, nearest first.
    _neighbors = List.generate(n, (_) => <int>[]);
    for (var i = 0; i < n; i++) {
      final near = <MapEntry<double, int>>[];
      for (var j = 0; j < n; j++) {
        if (i == j) continue;
        final dx = nodes[i].x - nodes[j].x;
        final dy = nodes[i].y - nodes[j].y;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d <= wireGap) near.add(MapEntry(d, j));
      }
      near.sort((a, b) => a.key.compareTo(b.key));
      _neighbors[i] = near.map((e) => e.value).toList();
    }

    indexes = [];
    worked = false;
    _steps = 0;
    if (n == 0) return;

    final visited = List.filled(n, false);
    final path = <int>[];
    visited[start] = true;
    path.add(start);
    indexes = List.of(path);
    _wireNode(visited, path);
  }

  void _wireNode(List<bool> visited, List<int> path) {
    if (worked) return;
    if (path.length > indexes.length) indexes = List.of(path);
    if (path.length == _neighbors.length) {
      worked = true;
      return;
    }
    if (++_steps > _maxSteps) return;

    final current = path.last;

    // Warnsdorff: try the neighbour with the fewest onward unwired neighbours
    // first; m_neighbors is nearest-first so ties prefer the closer node.
    final candidates = <MapEntry<int, int>>[]; // (onward degree, node)
    for (final next in _neighbors[current]) {
      if (visited[next]) continue;
      var onward = 0;
      for (final nn in _neighbors[next]) {
        if (!visited[nn]) onward++;
      }
      candidates.add(MapEntry(onward, next));
    }
    candidates.sort((a, b) => a.key.compareTo(b.key));

    for (final c in candidates) {
      final next = c.value;
      visited[next] = true;
      path.add(next);
      _wireNode(visited, path);
      path.removeLast();
      visited[next] = false;
      if (worked) return;
    }
  }
}
