import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The shared sign-in harness for the widget tests: the "boot → enter
// credentials → login → settle" sequence every screen test runs, kept in
// one place so the screens are what the tests express.

/// Submits the already-open login form: [username] and [password], then the
/// 登录 button, settled through to the signed-in screen.
Future<void> signIn(
    WidgetTester tester, String username, String password) async {
  await tester.enterText(find.byKey(const Key('username_field')), username);
  await tester.enterText(find.byKey(const Key('password_field')), password);
  await tester.tap(find.byKey(const Key('login_button')));
  await tester.pumpAndSettle();
}

/// Pumps [app] and signs in as [username] with [password] in one step.
Future<void> pumpAndLogin(
    WidgetTester tester, Widget app, String username, String password) async {
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
  await signIn(tester, username, password);
}
