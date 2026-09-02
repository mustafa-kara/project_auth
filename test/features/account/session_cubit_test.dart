/// SessionCubit testleri (Faz 3 Patch 1) — kimlik kapısı state makinesi.
///
/// libsodium GEREKMEZ — AuthRepository + pending store fake. Vault'a dokunulmaz
/// (onAuthSignedOut callback ile gevşek bağ doğrulanır).
library;

import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/features/account/data/pending_confirmation_store.dart';
import 'package:project_auth/features/account/domain/auth_exceptions.dart';
import 'package:project_auth/features/account/domain/auth_repository.dart';
import 'package:project_auth/features/account/presentation/bloc/session_cubit.dart';
import 'package:project_auth/features/account/presentation/bloc/session_state.dart';

class _FakeAuth implements AuthRepository {
  bool signedInAtStart = false;
  String uid = 'uid-A';
  final _controller = StreamController<AuthSessionState>.broadcast();

  SignUpOutcome signUpOutcome = SignUpOutcome.confirmPending;
  Object? signInError;
  Object? signOutError;
  int signOutCount = 0;

  @override
  AuthSessionState get current =>
      signedInAtStart ? AuthSessionState.signedIn : AuthSessionState.signedOut;

  @override
  String? get currentUserId => signedInAtStart ? uid : null;

  @override
  Stream<AuthSessionState> authStateChanges() => _controller.stream;

  void emitSignedIn() {
    signedInAtStart = true;
    _controller.add(AuthSessionState.signedIn);
  }

  void emitSignedOut() {
    signedInAtStart = false;
    _controller.add(AuthSessionState.signedOut);
  }

  void emitStreamError(Object e) => _controller.addError(e);

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
  }) async {
    if (signUpOutcome == SignUpOutcome.signedIn) signedInAtStart = true;
    return signUpOutcome;
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    if (signInError != null) throw signInError!;
    signedInAtStart = true;
  }

  @override
  Future<void> signOut() async {
    signOutCount++;
    signedInAtStart = false;
    if (signOutError != null) throw signOutError!;
  }

  @override
  Future<void> resendConfirmation(String email) async {}

  Future<void> dispose() => _controller.close();
}

/// In-memory FlutterSecureStorage (gerçek PendingConfirmationStore ile kullanılır).
class _FakeStorage implements FlutterSecureStorage {
  final Map<String, String> data = {};
  @override
  Future<String?> read({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async => data[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async => data.remove(key);
  @override
  noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

void main() {
  late _FakeAuth auth;
  late _FakeStorage storage;

  setUp(() {
    auth = _FakeAuth();
    storage = _FakeStorage();
  });

  tearDown(() async {
    await auth.dispose();
  });

  /// pending store'u doğrudan okumak/yazmak için yardımcı.
  PendingConfirmationStore pendingStore() =>
      PendingConfirmationStore(storage: storage);
  void seedPending(String email) =>
      storage.data[PendingConfirmationStore.storageKey] = email;
  String? readPending() => storage.data[PendingConfirmationStore.storageKey];

  SessionCubit build({
    LinkRequiredResolver? linkResolver,
    void Function()? onSignedOut,
  }) {
    return SessionCubit(
      auth: auth,
      pendingStore: pendingStore(),
      linkRequiredResolver: linkResolver,
      onAuthSignedOut: onSignedOut,
    );
  }

  test('bootstrap: oturum yok + pending yok → signedOut', () async {
    final cubit = build();
    await cubit.bootstrap();
    expect(cubit.state.status, SessionStatus.signedOut);
    await cubit.close();
  });

  test('bootstrap: pending dolu → emailConfirmPending (persist)', () async {
    seedPending('a@b.com');
    final cubit = build();
    await cubit.bootstrap();
    expect(cubit.state.status, SessionStatus.emailConfirmPending);
    expect(cubit.state.email, 'a@b.com');
    await cubit.close();
  });

  test(
    'bootstrap: current=signedIn ama pending dolu → pending temizlenir + signedIn '
    '(reviewer [P2] sıra)',
    () async {
      auth.signedInAtStart = true;
      seedPending('a@b.com');
      final cubit = build();
      await cubit.bootstrap();
      expect(cubit.state.status, SessionStatus.signedIn);
      expect(readPending(), isNull); // temizlendi
      await cubit.close();
    },
  );

  test('signIn başarı → signedIn', () async {
    final cubit = build();
    await cubit.bootstrap();
    await cubit.signIn(email: 'a@b.com', password: 'x');
    expect(cubit.state.status, SessionStatus.signedIn);
    await cubit.close();
  });

  test('signIn yanlış kimlik → error, signedOut kalır', () async {
    auth.signInError = const AuthInvalidCredentials();
    final cubit = build();
    await cubit.bootstrap();
    await cubit.signIn(email: 'a@b.com', password: 'x');
    expect(cubit.state.error, isA<AuthInvalidCredentials>());
    expect(cubit.state.status, isNot(SessionStatus.signedIn));
    await cubit.close();
  });

  test(
    'signIn onaysız e-posta → emailConfirmPending + email PERSIST + email dolu '
    '(resend çalışır — reviewer [P2])',
    () async {
      auth.signInError = const AuthEmailNotConfirmed();
      final cubit = build();
      await cubit.bootstrap();
      await cubit.signIn(email: 'a@b.com', password: 'x');
      expect(cubit.state.status, SessionStatus.emailConfirmPending);
      expect(cubit.state.email, 'a@b.com'); // confirm ekranı email null görmez
      expect(readPending(), 'a@b.com'); // persist
      expect(cubit.state.error, isA<AuthEmailNotConfirmed>());
      await cubit.close();
    },
  );

  test('signUp → emailConfirmPending + pending store\'a yazıldı', () async {
    final cubit = build();
    await cubit.bootstrap();
    await cubit.signUp(email: 'new@b.com', password: 'pw12345678');
    expect(cubit.state.status, SessionStatus.emailConfirmPending);
    expect(readPending(), 'new@b.com');
    await cubit.close();
  });

  test('signedIn (stream) gelince pending temizlenir', () async {
    seedPending('new@b.com');
    final cubit = build();
    await cubit.bootstrap();
    expect(cubit.state.status, SessionStatus.emailConfirmPending);
    auth.emitSignedIn();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.status, SessionStatus.signedIn);
    expect(readPending(), isNull);
    await cubit.close();
  });

  test(
    'signOut → signedOut + onAuthSignedOut çağrıldı (vault kilit bağı, reviewer [P1])',
    () async {
      var calledOnSignedOut = false;
      final cubit = build(onSignedOut: () => calledOnSignedOut = true);
      auth.signedInAtStart = true;
      await cubit.bootstrap();
      await cubit.signOut();
      expect(cubit.state.status, SessionStatus.signedOut);
      expect(calledOnSignedOut, isTrue);
      await cubit.close();
    },
  );

  test('signOut THROWS (ağ hatası) → onAuthSignedOut YİNE çağrıldı + signedOut '
      '(asla signedIn\'de kalmaz — reviewer [P2], #683)', () async {
    var calledOnSignedOut = false;
    auth.signOutError = const AuthNetworkError();
    final cubit = build(onSignedOut: () => calledOnSignedOut = true);
    auth.signedInAtStart = true;
    await cubit.bootstrap();
    await cubit.signOut();
    expect(calledOnSignedOut, isTrue);
    expect(cubit.state.status, SessionStatus.signedOut); // throw'a rağmen
    await cubit.close();
  });

  test(
    'stream onError → SessionState.error, cubit crash etmez (reviewer [P2])',
    () async {
      final cubit = build();
      await cubit.bootstrap();
      auth.emitStreamError(const AuthNetworkError());
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.error, isA<AuthNetworkError>());
      await cubit.close();
    },
  );

  test(
    'cancelPendingConfirmation → pending temiz + signedOut (confirm trap çıkışı)',
    () async {
      seedPending('a@b.com');
      final cubit = build();
      await cubit.bootstrap();
      expect(cubit.state.status, SessionStatus.emailConfirmPending);
      await cubit.cancelPendingConfirmation();
      expect(cubit.state.status, SessionStatus.signedOut);
      expect(readPending(), isNull);
      await cubit.close();
    },
  );

  group('linkRequired hydrate köprüsü (reviewer [P3])', () {
    test('bootstrap signedIn + resolver true → linkRequired:true', () async {
      auth.signedInAtStart = true;
      final cubit = build(linkResolver: (uid) async => true);
      await cubit.bootstrap();
      expect(cubit.state.status, SessionStatus.signedIn);
      expect(cubit.state.linkRequired, isTrue);
      await cubit.close();
    });

    test(
      'refreshLinkRequired (karar sonrası) → linkRequired:false yeniden emit',
      () async {
        auth.signedInAtStart = true;
        var decided = false;
        final cubit = build(linkResolver: (uid) async => !decided);
        await cubit.bootstrap();
        expect(cubit.state.linkRequired, isTrue);
        decided = true; // account-link kararı verildi
        await cubit.refreshLinkRequired();
        expect(cubit.state.linkRequired, isFalse);
        await cubit.close();
      },
    );

    test('resolver hatası login\'i bloklamaz → linkRequired:false', () async {
      auth.signedInAtStart = true;
      final cubit = build(linkResolver: (uid) async => throw Exception('boom'));
      await cubit.bootstrap();
      expect(cubit.state.status, SessionStatus.signedIn);
      expect(cubit.state.linkRequired, isFalse);
      await cubit.close();
    });
  });
}
