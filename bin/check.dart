// Headless check of the ported domain logic:
//   dart run bin/check.dart <file.dxf> [holeMm] [gapMm]
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:xmodelgen/src/auto_wire.dart';
import 'package:xmodelgen/src/dxf_data.dart';
import 'package:xmodelgen/src/dxf_reader.dart';
import 'package:xmodelgen/src/hole_finder.dart';
import 'package:xmodelgen/src/model.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    print('usage: dart run bin/check.dart <file.dxf> [holeMm] [gapMm]');
    return;
  }
  final diaMm = args.length > 1 ? double.parse(args[1]) : 12.0;
  final gapMm = args.length > 2 ? double.parse(args[2]) : 100.0;

  final text = File(args[0]).readAsStringSync();
  final dxf = parseDxf(text);
  final f = millimetersPerUnit(dxf.insUnits);
  final mmPerUnit = f <= 0 ? 1.0 : f;
  double mmToDrawing(double mm) => f <= 0 ? mm : mm / f;

  final holes = findHoles(dxf, mmToDrawing(diaMm), mmToDrawing(0.5));
  final model = Model()..name = 'check';
  for (final h in holes) {
    model.addNode(Node(h.x * mmPerUnit, h.y * mmPerUnit, radius: diaMm / 2));
  }
  print('units=${dxf.insUnits} blocks=${dxf.blocks.length} '
      'holes=${holes.length} nodes=${model.nodeCount}');

  if (model.nodeCount > 0) {
    final aw = AutoWire(model, gapMm)
      ..wireModel(model.nodes[0].x, model.nodes[0].y);
    model.clearWiring();
    var num = 1;
    for (final i in aw.indexes) {
      model.setNodeNumber(i, num++);
    }
    final xml = model.toXModel();
    final w = RegExp(r'parm1="(\d+)"').firstMatch(xml)?.group(1);
    final h = RegExp(r'parm2="(\d+)"').firstMatch(xml)?.group(1);
    print('wired=${aw.indexes.length}/${model.nodeCount} complete=${aw.worked} '
        'grid=${w}x$h');
  }
}
