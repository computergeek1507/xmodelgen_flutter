import 'dart:math' as math;

/// A circle-like element read from an SVG, in the app's node convention:
/// X right, Y up (SVG Y points down, so it is negated). [dia] is in millimetres.
class SvgCircle {
  SvgCircle(this.x, this.y, this.dia);
  final double x;
  final double y;
  final double dia;
}

/// 2D affine: x' = a*x + c*y + e, y' = b*x + d*y + f.
class _Affine {
  const _Affine(this.a, this.b, this.c, this.d, this.e, this.f);
  final double a, b, c, d, e, f;

  static const identity = _Affine(1, 0, 0, 1, 0, 0);

  /// this ∘ l — apply `l` first, then `this`.
  _Affine compose(_Affine l) => _Affine(
        a * l.a + c * l.b,
        b * l.a + d * l.b,
        a * l.c + c * l.d,
        b * l.c + d * l.d,
        a * l.e + c * l.f + e,
        b * l.e + d * l.f + f,
      );

  List<double> apply(double x, double y) => [a * x + c * y + e, b * x + d * y + f];

  double get scale => math.sqrt((a * d - b * c).abs());
}

/// Pull a list of numbers out of "f1(a,b) f2(c)" / viewBox text.
List<double> _numbers(String s) {
  final out = <double>[];
  final buf = StringBuffer();
  void flush() {
    if (buf.isNotEmpty) {
      final v = double.tryParse(buf.toString());
      if (v != null) out.add(v);
      buf.clear();
    }
  }

  for (final cu in s.codeUnits) {
    final ch = String.fromCharCode(cu);
    if ((cu >= 48 && cu <= 57) ||
        ch == '.' ||
        ch == '-' ||
        ch == '+' ||
        ch == 'e' ||
        ch == 'E') {
      buf.write(ch);
    } else {
      flush();
    }
  }
  flush();
  return out;
}

/// Parse an SVG `transform` attribute into a single affine (applied left-to-right).
_Affine _parseTransform(String spec) {
  var m = _Affine.identity;
  final re = RegExp(r'(\w+)\s*\(([^)]*)\)');
  for (final match in re.allMatches(spec)) {
    final name = match.group(1)!;
    final v = _numbers(match.group(2)!);
    _Affine t = _Affine.identity;
    switch (name) {
      case 'translate':
        t = _Affine(1, 0, 0, 1, v.isNotEmpty ? v[0] : 0, v.length > 1 ? v[1] : 0);
      case 'scale':
        final sx = v.isNotEmpty ? v[0] : 1.0;
        t = _Affine(sx, 0, 0, v.length > 1 ? v[1] : sx, 0, 0);
      case 'rotate':
        final ang = (v.isNotEmpty ? v[0] : 0) * math.pi / 180.0;
        final r = _Affine(math.cos(ang), math.sin(ang), -math.sin(ang),
            math.cos(ang), 0, 0);
        if (v.length >= 3) {
          final pre = _Affine(1, 0, 0, 1, v[1], v[2]);
          final post = _Affine(1, 0, 0, 1, -v[1], -v[2]);
          t = pre.compose(r).compose(post);
        } else {
          t = r;
        }
      case 'matrix':
        if (v.length >= 6) t = _Affine(v[0], v[1], v[2], v[3], v[4], v[5]);
      case 'skewX':
        if (v.isNotEmpty) t = _Affine(1, 0, math.tan(v[0] * math.pi / 180), 1, 0, 0);
      case 'skewY':
        if (v.isNotEmpty) t = _Affine(1, math.tan(v[0] * math.pi / 180), 0, 1, 0, 0);
    }
    m = m.compose(t);
  }
  return m;
}

/// Convert an SVG length ("200mm", "8.5in", "300px", "300") to millimetres, or
/// null if it has no recognised physical unit and isn't a bare number.
double? _lengthToMm(String s) {
  s = s.trim();
  final m = RegExp(r'^([+-]?[\d.eE]+)\s*([a-z%]*)$').firstMatch(s);
  if (m == null) return null;
  final num = double.tryParse(m.group(1)!);
  if (num == null) return null;
  switch (m.group(2)!.toLowerCase()) {
    case 'mm':
      return num;
    case 'cm':
      return num * 10.0;
    case 'in':
      return num * 25.4;
    case 'pt':
      return num * 25.4 / 72.0;
    case 'pc':
      return num * 25.4 / 6.0;
    case 'px':
    case '':
      return num * 25.4 / 96.0; // CSS px
    default:
      return null; // %, em, ...
  }
}

final _attrRe =
    RegExp('''([\\w:.-]+)\\s*=\\s*("[^"]*"|'[^']*')''');

Map<String, String> _attrs(String s) {
  final out = <String, String>{};
  for (final m in _attrRe.allMatches(s)) {
    out[m.group(1)!] = m.group(2)!.substring(1, m.group(2)!.length - 1);
  }
  return out;
}

/// Reads circle-like geometry from SVG source as candidate holes. `<circle>` and
/// near-circular `<ellipse>` centres are collected, element/group `transform`
/// attributes are applied, and coordinates are scaled to millimetres using the
/// root `<svg>` width + viewBox (falling back to 1 user unit = 1 mm).
List<SvgCircle> readSvgCircles(String text) {
  final stack = <_Affine>[];
  final raw = <List<double>>[]; // [x, y, r] in user units (world)
  var mmPerUnit = 1.0;

  var i = 0;
  while (i < text.length) {
    final lt = text.indexOf('<', i);
    if (lt < 0) break;
    // Find the matching '>' while respecting quoted attribute values.
    var j = lt + 1;
    String? quote;
    while (j < text.length) {
      final ch = text[j];
      if (quote != null) {
        if (ch == quote) quote = null;
      } else if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == '>') {
        break;
      }
      j++;
    }
    if (j >= text.length) break;
    var tag = text.substring(lt + 1, j).trim();
    i = j + 1;

    if (tag.isEmpty || tag.startsWith('!') || tag.startsWith('?')) continue;

    if (tag.startsWith('/')) {
      if (stack.isNotEmpty) stack.removeLast();
      continue;
    }

    final selfClose = tag.endsWith('/');
    if (selfClose) tag = tag.substring(0, tag.length - 1);

    final sp = tag.indexOf(RegExp(r'\s'));
    final name = (sp < 0 ? tag : tag.substring(0, sp)).toLowerCase();
    final attrs = sp < 0 ? const <String, String>{} : _attrs(tag.substring(sp));

    final elemT =
        attrs.containsKey('transform') ? _parseTransform(attrs['transform']!) : _Affine.identity;
    final cur = stack.isEmpty ? elemT : stack.last.compose(elemT);

    if (name == 'svg') {
      final widthMm = attrs.containsKey('width') ? _lengthToMm(attrs['width']!) : null;
      if (widthMm != null && widthMm > 0 && attrs.containsKey('viewBox')) {
        final vb = _numbers(attrs['viewBox']!);
        if (vb.length >= 4 && vb[2] > 0) mmPerUnit = widthMm / vb[2];
      }
    } else if (name == 'circle') {
      final cx = double.tryParse(attrs['cx'] ?? '0') ?? 0;
      final cy = double.tryParse(attrs['cy'] ?? '0') ?? 0;
      final r = double.tryParse(attrs['r'] ?? '');
      if (r != null && r > 0) {
        final p = cur.apply(cx, cy);
        raw.add([p[0], p[1], r * cur.scale]);
      }
    } else if (name == 'ellipse') {
      final cx = double.tryParse(attrs['cx'] ?? '0') ?? 0;
      final cy = double.tryParse(attrs['cy'] ?? '0') ?? 0;
      final rx = double.tryParse(attrs['rx'] ?? '');
      final ry = double.tryParse(attrs['ry'] ?? '');
      // Only near-circular ellipses count as holes.
      if (rx != null && ry != null && rx > 0 && ry > 0 &&
          (rx - ry).abs() <= 0.2 * math.max(rx, ry)) {
        final p = cur.apply(cx, cy);
        raw.add([p[0], p[1], 0.5 * (rx + ry) * cur.scale]);
      }
    }

    if (!selfClose) stack.add(cur);
  }

  return [
    for (final c in raw)
      // To mm, flipping Y (SVG down -> node up).
      SvgCircle(c[0] * mmPerUnit, -c[1] * mmPerUnit, 2.0 * c[2] * mmPerUnit),
  ];
}
