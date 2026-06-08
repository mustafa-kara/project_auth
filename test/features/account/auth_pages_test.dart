/// Login/Register widget testleri (Faz 3 Patch 1).
///
/// libsodium GEREKMEZ — fake AuthRepository + in-memory store. Alan validasyonu,
/// buton→cubit metodu, hata→inline mesaj doğrulanır.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/features/account/data/pending_confirmation_store.dart';
import 'package:project_auth/features/account/domain/auth_exceptions.dart';
import 'package:project_auth/features/account/domain/auth_repository.dart';
import 'package:project_auth/features/account/presentation/bloc/session_cubit.dart';
import 'package:project_auth/features/account/presentation/pages/login_page.dart';
import 'package:project_auth/features/account/presentation/pages/register_page.dart';

class _FakeStorage implements FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => data[key];
  @override
  Future<void> write({required String key, required String? value, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({required String key, dynamic iOptions, dynamic aOptions, dynamic lOptions, dynamic webOptions, dynamic mOptions, dynamic wOptions}) async => data.remove(key);
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

class _FakeAuth implements AuthRepository {
  Object? signInError;
  int signInCount = 0;
  int signUpCount = 0;
  String? lastEmail;
  String? lastPassword;
  final _c = StreamController<AuthSessionState>.broadcast();

  @override
  AuthSessionState get current => AuthSessionState.signedOut;
  @override
  String? get currentUserId => null;
  @override
  Stream<AuthSessionState> authStateChanges() => _c.stream;
  @override
  Future<SignUpOutcome> signUp({required String email, required String password}) async {
    signUpCount++;
    lastEmail = email;
    lastPassword = password;
    return SignUpOutcome.confirmPending;
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    signInCount++;
    lastEmail = email;
    lastPassword = password;
    if (signInError != null) throw signInError!;
  }

  @override
  Future<void> signOut() async {}
  @override
  Future<void> resendConfirmation(String email) async {}
  Future<void> dispose() => _c.close();
}

void main() {
  late _FakeAuth auth;
  late SessionCubit cubit;

  setUp(() {
    auth = _FakeAuth();
    cubit = SessionCubit(
      auth: auth,
      pendingStore: PendingConfirmationStore(storage: _FakeStorage()),
    );
  });

  tearDown(() async {
    await cubit.close();
    await auth.dispose();
  });

  Widget wrap(Widget page) => MaterialApp(
        home: BlocProvider<SessionCubit>.value(value: cubit, child: page),
      );

  group('LoginPage', () {
    testWidgets('alanlar dolu + Giriş yap → signIn çağrılır', (tester) async {
      await tester.pumpWidget(wrap(const LoginPage()));
      await tester.enterText(find.byType(TextFormField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextFormField).at(1), 'parola12');
      await tester.tap(find.widgetWithText(FilledButton, 'Giriş yap'));
      await tester.pump();
      expect(auth.signInCount, 1);
      expect(auth.lastEmail, 'a@b.com');
    });

    testWidgets('yanlış kimlik → inline hata gösterilir', (tester) async {
      auth.signInError = const AuthInvalidCredentials();
      await tester.pumpWidget(wrap(const LoginPage()));
      await tester.enterText(find.byType(TextFormField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextFormField).at(1), 'wrong');
      await tester.tap(find.widgetWithText(FilledButton, 'Giriş yap'));
      await tester.pumpAndSettle();
      expect(find.text('E-posta veya parola hatalı.'), findsOneWidget);
    });
  });

  group('RegisterPage', () {
    testWidgets('parolalar eşleşmiyor → inline hata, signUp ÇAĞRILMAZ',
        (tester) async {
      await tester.pumpWidget(wrap(const RegisterPage()));
      await tester.enterText(find.byType(TextFormField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextFormField).at(1), 'parola12');
      await tester.enterText(find.byType(TextFormField).at(2), 'farkli99');
      await tester.tap(find.widgetWithText(FilledButton, 'Kayıt ol'));
      await tester.pump();
      expect(find.text('Parolalar eşleşmiyor.'), findsOneWidget);
      expect(auth.signUpCount, 0);
    });

    testWidgets('kısa parola → inline hata', (tester) async {
      await tester.pumpWidget(wrap(const RegisterPage()));
      await tester.enterText(find.byType(TextFormField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextFormField).at(1), 'kisa');
      await tester.enterText(find.byType(TextFormField).at(2), 'kisa');
      await tester.tap(find.widgetWithText(FilledButton, 'Kayıt ol'));
      await tester.pump();
      expect(find.text('Parola en az 8 karakter olmalı.'), findsOneWidget);
      expect(auth.signUpCount, 0);
    });

    testWidgets('geçerli form → signUp çağrılır', (tester) async {
      await tester.pumpWidget(wrap(const RegisterPage()));
      await tester.enterText(find.byType(TextFormField).at(0), 'new@b.com');
      await tester.enterText(find.byType(TextFormField).at(1), 'parola12');
      await tester.enterText(find.byType(TextFormField).at(2), 'parola12');
      await tester.tap(find.widgetWithText(FilledButton, 'Kayıt ol'));
      await tester.pump();
      expect(auth.signUpCount, 1);
      expect(auth.lastEmail, 'new@b.com');
    });
  });
}
