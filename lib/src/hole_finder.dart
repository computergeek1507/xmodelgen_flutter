import 'dart:math' as math;
import 'dxf_data.dart';

class Hole {
  Hole(this.x, this.y);
  final double x, y;
}

const int _kMinLoopVertices = 6;
const double _kRoundnessFactor = 0.25;
const int _kMaxInsertDepth = 24;

/// 2D affine: x' = a*x + c*y + e, y' = b*x + d*y + f.
class _Affine {
  const _Affine([
    this.a = 1,
    this.b = 0,
    this.c = 0,
    this.d = 1,
    this.e = 0,
    this.f = 0,
  ]);
  final double a, b, c, d, e, f;

  List<double> apply(double x, double y) => [a * x + c * y + e, b * x + d * y + f];
  double get scale => math.sqrt((a * d - b * c).abs());
}

_Affine _compose(_Affine p, _Affine l) => _Affine(
      p.a * l.a + p.c * l.b,
      p.b * l.a + p.d * l.b,
      p.a * l.c + p.c * l.d,
      p.b * l.c + p.d * l.d,
      p.a * l.e + p.c * l.f + p.e,
      p.b * l.e + p.d * l.f + p.f,
    );

_Affine _insertAffine(Insert ins, double bx, double by, double ix, double iy) {
  final ang = ins.angle * math.pi / 180.0;
  final cosA = math.cos(ang), sinA = math.sin(ang);
  return _Affine(
    cosA * ins.sx,
    sinA * ins.sx,
    -sinA * ins.sy,
    cosA * ins.sy,
    ix - cosA * ins.sx * bx + sinA * ins.sy * by,
    iy - sinA * ins.sx * bx - cosA * ins.sy * by,
  );
}

void _flattenInto(DxfData data, Geometry geo, _Affine t, int depth, Geometry out) {
  final scale = t.scale;
  for (final c in geo.circles) {
    final p = t.apply(c.cx, c.cy);
    out.circles.add(CircleData(p[0], p[1], c.radius * scale));
  }
  for (final a in geo.arcs) {
    final p = t.apply(a.cx, a.cy);
    out.arcs.add(ArcData(p[0], p[1], a.radius * scale));
  }
  for (final pl in geo.polylines) {
    final wpl = PolyLine()..flags = pl.flags;
    for (final v in pl.vertices) {
      final p = t.apply(v.x, v.y);
      wpl.vertices.add(Vertex(p[0], p[1]));
    }
    out.polylines.add(wpl);
  }
  for (final ln in geo.lines) {
    final a = t.apply(ln.x1, ln.y1);
    final b = t.apply(ln.x2, ln.y2);
    out.lines.add(LineData(a[0], a[1], b[0], b[1]));
  }

  if (depth >= _kMaxInsertDepth) return;
  for (final ins in geo.inserts) {
    final block = data.blocks[ins.blockName];
    if (block == null) continue;
    final cols = math.max(1, ins.cols);
    final rows = math.max(1, ins.rows);
    final ang = ins.angle * math.pi / 180.0;
    final cosA = math.cos(ang), sinA = math.sin(ang);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final dx = c * ins.colSp, dy = r * ins.rowSp;
        final ix = ins.x + cosA * dx - sinA * dy;
        final iy = ins.y + sinA * dx + cosA * dy;
        final local = _insertAffine(ins, block.bx, block.by, ix, iy);
        _flattenInto(data, block, _compose(t, local), depth + 1, out);
      }
    }
  }
}

Geometry flatten(DxfData data) {
  final out = Geometry();
  _flattenInto(data, data.model, const _Affine(), 0, out);
  return out;
}

bool _loopIsHole(List<Vertex> pts, double targetRadius, double tol, List<double> outCenter) {
  if (pts.length < _kMinLoopVertices) return false;
  var sx = 0.0, sy = 0.0;
  for (final p in pts) {
    sx += p.x;
    sy += p.y;
  }
  final cx = sx / pts.length, cy = sy / pts.length;
  var meanR = 0.0;
  for (final p in pts) {
    meanR += math.sqrt(math.pow(p.x - cx, 2) + math.pow(p.y - cy, 2));
  }
  meanR /= pts.length;
  if (meanR <= 0 || (meanR - targetRadius).abs() > tol) return false;
  final roundTol = meanR * _kRoundnessFactor;
  for (final p in pts) {
    final d = math.sqrt(math.pow(p.x - cx, 2) + math.pow(p.y - cy, 2));
    if ((d - meanR).abs() > roundTol) return false;
  }
  outCenter[0] = cx;
  outCenter[1] = cy;
  return true;
}

/// Finds hole centres whose radius is within [radiusTolerance] of [diameter]/2.
List<Hole> findHoles(DxfData data, double diameter, double radiusTolerance) {
  final geo = flatten(data);
  final targetRadius = diameter / 2.0;
  bool radiusMatches(double r) => (r - targetRadius).abs() <= radiusTolerance;

  final holes = <Hole>[];
  for (final c in geo.circles) {
    if (radiusMatches(c.radius)) holes.add(Hole(c.cx, c.cy));
  }
  for (final a in geo.arcs) {
    if (radiusMatches(a.radius)) holes.add(Hole(a.cx, a.cy));
  }
  for (final pl in geo.polylines) {
    final center = [0.0, 0.0];
    if (_loopIsHole(pl.vertices, targetRadius, radiusTolerance, center)) {
      holes.add(Hole(center[0], center[1]));
    }
  }

  // Loops formed by connected line segments (circles exploded into lines).
  if (geo.lines.isNotEmpty) {
    final weld = math.max(diameter * 0.02, 1e-9);
    final parent = <int>[];
    final coord = <Vertex>[];
    final index = <int, int>{};

    int vertexAt(double x, double y) {
      final gx = (x / weld).round();
      final gy = (y / weld).round();
      final key = gx * 100000000 + gy;
      final found = index[key];
      if (found != null) return found;
      final id = parent.length;
      parent.add(id);
      coord.add(Vertex(x, y));
      index[key] = id;
      return id;
    }

    int find(int a) {
      while (parent[a] != a) {
        parent[a] = parent[parent[a]];
        a = parent[a];
      }
      return a;
    }

    void unite(int a, int b) {
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[ra] = rb;
    }

    for (final ln in geo.lines) {
      unite(vertexAt(ln.x1, ln.y1), vertexAt(ln.x2, ln.y2));
    }

    final comps = <int, List<Vertex>>{};
    for (var k = 0; k < parent.length; k++) {
      comps.putIfAbsent(find(k), () => []).add(coord[k]);
    }
    for (final pts in comps.values) {
      final center = [0.0, 0.0];
      if (_loopIsHole(pts, targetRadius, radiusTolerance, center)) {
        holes.add(Hole(center[0], center[1]));
      }
    }
  }

  return holes;
}
