import 'dxf_data.dart';

/// A minimal DXF parser covering the entities xModelGen needs: CIRCLE, ARC,
/// LWPOLYLINE, LINE, INSERT, BLOCK definitions, and the $INSUNITS header.
///
/// Unlike the pub `dxf` package, this expands block references (INSERTs), so
/// holes placed via inserted blocks are found at their real positions.
/// Geometry inside a block definition is stored on that block; other geometry
/// goes to model space.
DxfData parseDxf(String text) {
  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  final pairs = <MapEntry<int, String>>[];
  // A DXF is (group code, value) line pairs. Pair sequentially and skip any
  // line whose "code" isn't an integer, so stray lines don't flip the parity.
  for (var k = 0; k + 1 < lines.length;) {
    final code = int.tryParse(lines[k].trim());
    if (code == null) {
      k++;
      continue;
    }
    pairs.add(MapEntry(code, lines[k + 1].trim()));
    k += 2;
  }

  final data = DxfData();

  // $INSUNITS lives in the HEADER section as a code-9 variable followed by its
  // code-70 value; find it directly (the entity loop skips header variables).
  for (var k = 0; k + 1 < pairs.length; k++) {
    if (pairs[k].key == 9 &&
        pairs[k].value == r'$INSUNITS' &&
        pairs[k + 1].key == 70) {
      data.insUnits = int.tryParse(pairs[k + 1].value) ?? 0;
      break;
    }
  }

  Block? currentBlock;

  Geometry target() => currentBlock ?? data.model;

  var i = 0;
  while (i < pairs.length) {
    final p = pairs[i];

    if (p.key != 0) {
      i++;
      continue;
    }

    final entity = p.value;
    var j = i + 1;
    final fields = <MapEntry<int, String>>[];
    while (j < pairs.length && pairs[j].key != 0) {
      fields.add(pairs[j]);
      j++;
    }

    double f(int code, [double def = 0]) {
      for (final e in fields) {
        if (e.key == code) return double.tryParse(e.value) ?? def;
      }
      return def;
    }

    String s(int code, [String def = '']) {
      for (final e in fields) {
        if (e.key == code) return e.value;
      }
      return def;
    }

    switch (entity) {
      case 'BLOCK':
        final b = Block()
          ..name = s(2)
          ..bx = f(10)
          ..by = f(20);
        data.blocks[b.name] = b;
        currentBlock = b;
        break;
      case 'ENDBLK':
        currentBlock = null;
        break;
      case 'CIRCLE':
        target().circles.add(CircleData(f(10), f(20), f(40)));
        break;
      case 'ARC':
        target().arcs.add(ArcData(f(10), f(20), f(40)));
        break;
      case 'LINE':
        target().lines.add(LineData(f(10), f(20), f(11), f(21)));
        break;
      case 'LWPOLYLINE':
        final pl = PolyLine()..flags = f(70).toInt();
        double? vx;
        for (final e in fields) {
          if (e.key == 10) {
            vx = double.tryParse(e.value);
          } else if (e.key == 20 && vx != null) {
            pl.vertices.add(Vertex(vx, double.tryParse(e.value) ?? 0));
            vx = null;
          }
        }
        target().polylines.add(pl);
        break;
      case 'INSERT':
        target().inserts.add(Insert()
          ..blockName = s(2)
          ..x = f(10)
          ..y = f(20)
          ..sx = f(41, 1)
          ..sy = f(42, 1)
          ..angle = f(50)
          ..cols = f(70, 1).toInt()
          ..rows = f(71, 1).toInt()
          ..colSp = f(44)
          ..rowSp = f(45));
        break;
    }

    i = j;
  }

  return data;
}
