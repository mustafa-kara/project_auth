/// Faz 3 Patch 4 Adım G — Settings duyuru salt-okunur bölüm widget testi.
///
/// Duyurular cache/ağdan yüklenir, audience filtreli gösterilir; servis yoksa bölüm gizli.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/features/account/data/announcements_cache_store.dart';
import 'package:project_auth/features/account/domain/announcements_repository.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_cubit.dart';
import 'package:project_auth/features/auth/presentation/bloc/vault_lock_state.dart';
import 'package:project_auth/features/settings/presentation/settings_page.dart';

class _FakeLockCubit extends Cubit<VaultLockState> implements VaultLockCubit {
  _FakeLockCubit()
      : super(VaultLockState.unlocked(
            biometricEnrolled: false, deviceBiometricAvailable: false));
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeAnnRepo implements AnnouncementsRepository {
  _FakeAnnRepo(this.items, {this.throwError = false});
  final List<Announcement> items;
  final bool throwError;
  @override
  Future<List<Announcement>> fetchAll() async {
    if (throwError) throw const _Err();
    return items;
  }
}

class _Err implements Exception {
  const _Err();
}

class _NoCache implements AnnouncementsCacheStore {
  @override
  Future<List<Announcement>?> read() async => null;
  @override
  Future<void> write(List<Announcement> items) async {}
  @override
  Future<void> clear() async {}
}

Announcement _ann(String id, String title, String audience) => Announcement(
      id: id, title: title, body: 'Body $id', audience: audience,
      createdAt: DateTime.utc(2026, 6, 10),
    );

Widget _wrap(Widget child,
    {AnnouncementsRepository? repo, AnnouncementsCacheStore? cache}) {
  Widget tree = MaterialApp(home: child);
  if (repo != null && cache != null) {
    tree = RepositoryProvider<AnnouncementsRepository>.value(
      value: repo,
      child: RepositoryProvider<AnnouncementsCacheStore>.value(
        value: cache,
        child: tree,
      ),
    );
  }
  return BlocProvider<VaultLockCubit>.value(value: _FakeLockCubit(), child: tree);
}

void main() {
  testWidgets('servis yok → duyuru bölümü GİZLİ', (tester) async {
    await tester.pumpWidget(_wrap(const SettingsPage()));
    await tester.pumpAndSettle();
    expect(find.text('Duyurular'), findsNothing);
  });

  testWidgets('audience eşleşen duyurular listelenir; eşleşmeyen gizli', (tester) async {
    final repo = _FakeAnnRepo([
      _ann('1', 'Herkese', 'all'),
      _ann('2', 'Sadece web', 'web'), // platform eşleşmez (test host)
    ]);
    await tester.pumpWidget(_wrap(const SettingsPage(), repo: repo, cache: _NoCache()));
    await tester.pumpAndSettle();
    expect(find.text('Duyurular'), findsOneWidget);
    expect(find.text('Herkese'), findsOneWidget);
    expect(find.text('Sadece web'), findsNothing);
  });

  testWidgets('boş duyuru → bölüm gizli', (tester) async {
    final repo = _FakeAnnRepo(const []);
    await tester.pumpWidget(_wrap(const SettingsPage(), repo: repo, cache: _NoCache()));
    await tester.pumpAndSettle();
    expect(find.text('Duyurular'), findsNothing);
  });

  testWidgets('ağ hatası + cache yok → bölüm gizli (sessiz)', (tester) async {
    final repo = _FakeAnnRepo(const [], throwError: true);
    await tester.pumpWidget(_wrap(const SettingsPage(), repo: repo, cache: _NoCache()));
    await tester.pumpAndSettle();
    expect(find.text('Duyurular'), findsNothing);
  });
}
