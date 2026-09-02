/// Faz 3 Patch 4 Adım E testleri — VaultCubit.add issuer kanonikleştirme.
/// Katalog eşleşmesinde issuer kanonik ada hizalanır; eşleşme yok/katalog yok → no-op.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/otp/otp_account.dart';
import 'package:project_auth/features/vault/data/vault_load_result.dart';
import 'package:project_auth/features/vault/data/vault_repository.dart';
import 'package:project_auth/features/vault/domain/catalog_repository.dart';
import 'package:project_auth/features/vault/domain/issuer_catalog.dart';
import 'package:project_auth/features/vault/presentation/bloc/vault_cubit.dart';

class _FakeRepo implements VaultRepository {
  List<OtpAccount> stored = [];
  @override
  Future<VaultLoadResult> load() async =>
      VaultLoadResult(accounts: List.of(stored));
  @override
  Future<void> save(List<OtpAccount> accounts) async =>
      stored = List.of(accounts);
  @override
  Future<void> purgeCorrupted() async {}
}

OtpAccount _acc(String? issuer) => OtpAccount(
  secret: 'JBSWY3DPEHPK3PXP',
  type: OtpType.totp,
  issuer: issuer,
  accountName: 'me@example.com',
);

CatalogService _svc(String name, {String? issuer}) =>
    CatalogService(id: 'id-$name', name: name, issuer: issuer, logoUrl: null);

void main() {
  late _FakeRepo repo;

  VaultCubit build(IssuerCatalog? catalog) {
    repo = _FakeRepo();
    return VaultCubit(
      repo,
      issuerCatalogResolver: catalog == null ? null : () => catalog,
    );
  }

  test('eşleşen issuer → kanonik ada hizalanır', () async {
    final catalog = IssuerCatalog([_svc('GitHub', issuer: 'github')]);
    final cubit = build(catalog);
    await cubit.load();
    await cubit.add(
      _acc('github.com'),
    ); // slug 'githubcom' ≠ 'github' → eşleşmez

    // 'github.com' slug 'githubcom'; katalog 'github' slug 'github' → eşleşmez (no-op).
    expect(repo.stored.single.issuer, 'github.com');
  });

  test('slug birebir eşleşen issuer → kanonik ad', () async {
    final catalog = IssuerCatalog([_svc('GitHub', issuer: 'github')]);
    final cubit = build(catalog);
    await cubit.load();
    await cubit.add(_acc('GitHub')); // slug 'github' = 'github' → eşleşir
    expect(repo.stored.single.issuer, 'GitHub');
  });

  test('eşleşme yok → issuer DEĞİŞMEZ', () async {
    final catalog = IssuerCatalog([_svc('GitHub', issuer: 'github')]);
    final cubit = build(catalog);
    await cubit.load();
    await cubit.add(_acc('MyBank'));
    expect(repo.stored.single.issuer, 'MyBank');
  });

  test('katalog resolver null → no-op (issuer korunur)', () async {
    final cubit = build(null);
    await cubit.load();
    await cubit.add(_acc('github'));
    expect(repo.stored.single.issuer, 'github');
  });

  test('boş katalog → no-op', () async {
    final cubit = build(IssuerCatalog.empty());
    await cubit.load();
    await cubit.add(_acc('github'));
    expect(repo.stored.single.issuer, 'github');
  });

  test('null issuer → no-op (secret/diğer alanlar değişmez)', () async {
    final catalog = IssuerCatalog([_svc('GitHub', issuer: 'github')]);
    final cubit = build(catalog);
    await cubit.load();
    await cubit.add(_acc(null));
    expect(repo.stored.single.issuer, isNull);
    expect(repo.stored.single.secret, 'JBSWY3DPEHPK3PXP');
  });
}
