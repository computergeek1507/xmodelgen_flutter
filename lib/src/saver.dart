// Picks the right implementation: dart:io on desktop, a browser download on web.
export 'saver_io.dart' if (dart.library.html) 'saver_web.dart';
