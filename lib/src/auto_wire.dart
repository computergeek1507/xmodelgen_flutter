import 'dart:math' as math;
import 'model.dart';

/// Move-ordering strategy for [AutoWire].
///
/// - [nearestFirst] always tries the closest unwired node first. Gives the
///   tidiest (shortest-hop) wiring, but can fail to complete from some start
///   nodes because it greedily strands the perimeter; bounded by a low step
///   budget so it gives up quickly instead of grinding.
/// - [warnsdorff] tries the node with the fewest onward moves first (distance
///   only breaks ties). Reliably completes from almost any start, at the cost
///   of longer hops.
enum WireStrategy { nearestFirst, warnsdorff }

/// Finds a wiring order by recursive backtracking. Starting from a node it hops
/// to any not-yet-wired node within [wireGap] (so it can skip a near node and
/// pick it up later), backtracking on dead ends. Keeps the longest path if none
/// is complete. The [strategy] trades wiring tidiness against reliability.
class AutoWire {
  AutoWire(this.model, this.wireGap,
      {this.strategy = WireStrategy.nearestFirst});

  final Model model;
  final double wireGap;
  final WireStrategy strategy;

  List<int> indexes = [];
  bool worked = false;

  late List<List<int>> _neighbors;
  int _steps = 0;
  late int _maxSteps;

  // Warnsdorff reliably completes in a few hundred steps; a high cap only bites
  // on genuinely impossible gaps.
  static const int _warnsdorffMaxSteps = 5000000;

  // Nearest-first solves easy starts almost immediately but can chase an
  // unsolvable greedy trap forever, so bound it low: it gives up quickly
  // (keeping the best partial) and the user can switch to Warnsdorff.
  static const int _nearestMaxSteps = 500000;

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
    _maxSteps = strategy == WireStrategy.warnsdorff
        ? _warnsdorffMaxSteps
        : _nearestMaxSteps;
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

    // Build the order in which to try the unwired neighbours. _neighbors is
    // presorted nearest-first, so a stable sort on the key preserves distance
    // order within equal keys (the tie-breaker either way).
    final cand = <_Candidate>[];
    for (final next in _neighbors[current]) {
      if (visited[next]) continue;
      // `current` is still marked visited, so this onward count already excludes
      // the node we'd be arriving from.
      var onward = 0;
      for (final nn in _neighbors[next]) {
        if (!visited[nn]) onward++;
      }
      final int key;
      if (strategy == WireStrategy.warnsdorff) {
        // Fewest onward moves first (distance breaks ties via insertion order).
        key = onward;
      } else {
        // Nearest-first, but promote "forced" moves: a neighbour left with at
        // most one unwired neighbour must be taken soon or it gets stranded.
        key = onward <= 1 ? 0 : 1;
      }
      cand.add(_Candidate(key, next));
    }
    // Dart's List.sort is not stable, so include the nearest-first insertion
    // index in the comparator to keep distance order within equal keys.
    for (var i = 0; i < cand.length; i++) {
      cand[i].order = i;
    }
    cand.sort((a, b) =>
        a.key != b.key ? a.key - b.key : a.order - b.order);

    for (final c in cand) {
      final next = c.node;
      visited[next] = true;
      path.add(next);
      // Prune branches that can never complete: if hopping to `next` strands
      // any still-unwired node in an unreachable pocket, no full path follows.
      // This is what stops the search blowing up at small wire gaps, where the
      // graph is sparse and most branches dead-end.
      if (_allReachable(visited, next)) {
        _wireNode(visited, path);
      }
      path.removeLast();
      visited[next] = false;
      if (worked) return;
    }
  }

  /// True if every still-unwired node is reachable from [from] travelling only
  /// through other unwired nodes. A flood fill over the remaining subgraph.
  bool _allReachable(List<bool> visited, int from) {
    final n = visited.length;
    var unvisited = 0;
    for (var i = 0; i < n; i++) {
      if (!visited[i]) unvisited++;
    }
    if (unvisited == 0) return true;

    final seen = List.filled(n, false);
    final stack = <int>[];
    for (final nb in _neighbors[from]) {
      if (!visited[nb] && !seen[nb]) {
        seen[nb] = true;
        stack.add(nb);
      }
    }
    var reached = 0;
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      reached++;
      for (final nb in _neighbors[node]) {
        if (!visited[nb] && !seen[nb]) {
          seen[nb] = true;
          stack.add(nb);
        }
      }
    }
    return reached == unvisited;
  }
}

/// A neighbour candidate awaiting ordering: [key] is the strategy sort key and
/// [order] its nearest-first rank, used as a stable tie-breaker.
class _Candidate {
  _Candidate(this.key, this.node);
  final int key;
  final int node;
  int order = 0;
}
