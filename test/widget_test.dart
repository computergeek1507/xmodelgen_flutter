import 'package:flutter_test/flutter_test.dart';

import 'package:xmodelgen/main.dart';

void main() {
  testWidgets('App shows the toolbar', (WidgetTester tester) async {
    await tester.pumpWidget(const XModelGenApp());
    expect(find.text('Open DXF'), findsOneWidget);
    expect(find.text('Auto Wire'), findsOneWidget);
  });
}
