/// DXF geometry containers (mirrors the C++ dxf_data).
class CircleData {
  CircleData(this.cx, this.cy, this.radius);
  double cx, cy, radius;
}

class ArcData {
  ArcData(this.cx, this.cy, this.radius);
  double cx, cy, radius;
}

class LineData {
  LineData(this.x1, this.y1, this.x2, this.y2);
  double x1, y1, x2, y2;
}

class Vertex {
  Vertex(this.x, this.y);
  double x, y;
}

class PolyLine {
  final List<Vertex> vertices = [];
  int flags = 0;
  bool get isClosed => (flags & 1) != 0;
}

class Insert {
  String blockName = '';
  double x = 0, y = 0;
  double sx = 1, sy = 1;
  double angle = 0; // degrees
  int cols = 1, rows = 1;
  double colSp = 0, rowSp = 0;
}

class Geometry {
  final List<CircleData> circles = [];
  final List<ArcData> arcs = [];
  final List<PolyLine> polylines = [];
  final List<LineData> lines = [];
  final List<Insert> inserts = [];
}

class Block extends Geometry {
  String name = '';
  double bx = 0, by = 0;
}

class DxfData {
  final Geometry model = Geometry();
  final Map<String, Block> blocks = {};
  int insUnits = 0; // 0 unknown, 1 inches, 4 mm, ...
}

/// Millimetres per single drawing unit for a given $INSUNITS code (0 if unknown).
double millimetersPerUnit(int insUnits) {
  switch (insUnits) {
    case 1:
      return 25.4; // inches
    case 2:
      return 304.8; // feet
    case 4:
      return 1.0; // mm
    case 5:
      return 10.0; // cm
    case 6:
      return 1000.0; // m
    case 10:
      return 914.4; // yards
    case 13:
      return 0.001; // microns
    case 14:
      return 100.0; // decimetres
    default:
      return 0.0;
  }
}
