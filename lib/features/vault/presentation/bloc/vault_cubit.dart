/// Vault durumu — kayıtlı OTP hesaplarının listesi.
///
/// Faz 1 başlangıç: in-memory. Sonraki adım: flutter_secure_storage ile
/// kalıcılık (şifresiz, OS koruması). Faz 2: masterKey ile E2E şifreleme.
library;

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/otp/otp_account.dart';

class VaultState extends Equatable {
  final List<OtpAccount> accounts;

  const VaultState({this.accounts = const []});

  VaultState copyWith({List<OtpAccount>? accounts}) =>
      VaultState(accounts: accounts ?? this.accounts);

  @override
  List<Object?> get props => [accounts];
}

class VaultCubit extends Cubit<VaultState> {
  VaultCubit() : super(const VaultState());

  void add(OtpAccount account) {
    emit(state.copyWith(accounts: [...state.accounts, account]));
  }

  /// Stabil token id'sine göre siler (index değil — liste reorder/eşzamanlı
  /// değişimde yanlış öğeyi silmeyi önler).
  void removeById(String id) {
    final next = state.accounts.where((a) => a.id != id).toList();
    if (next.length == state.accounts.length) return; // bulunamadı
    emit(state.copyWith(accounts: next));
  }

  /// HOTP sayaç artırma (kod isteğe bağlı yenilenir). id-bazlı.
  void incrementCounter(String id) {
    final next = [
      for (final a in state.accounts)
        (a.id == id && a.type == OtpType.hotp)
            ? a.copyWith(counter: a.counter + 1)
            : a,
    ];
    emit(state.copyWith(accounts: next));
  }
}
