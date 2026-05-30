import 'dart:io';

import 'package:file_picker/file_picker.dart';

/// Desktop/mobile: ask for a path and write the file.
Future<bool> saveTextFile(String suggestedName, String content) async {
  final path = await FilePicker.saveFile(
    dialogTitle: 'Export xModel',
    fileName: suggestedName,
    type: FileType.any,
  );
  if (path == null) return false;
  await File(path).writeAsString(content);
  return true;
}
