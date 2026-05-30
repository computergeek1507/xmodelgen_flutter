// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:html' as html;

/// Web: trigger a browser download of the content.
Future<bool> saveTextFile(String suggestedName, String content) async {
  final bytes = utf8.encode(content);
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = suggestedName
    ..click();
  html.Url.revokeObjectUrl(url);
  return true;
}
