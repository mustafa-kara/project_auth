/// Bağımlılık enjeksiyonu composition root (get_it, manuel kayıt).
///
/// Faz 0: yalnızca saf/sunucusuz servisler. injectable codegen'e geçiş
/// ileride yapılabilir; şimdilik açık manuel kayıt sürtünmesizdir.
library;

import 'package:get_it/get_it.dart';

import '../otp/otp_generator.dart';

final GetIt locator = GetIt.instance;

Future<void> configureDependencies() async {
  // Çekirdek OTP motoru — durumsuz, paylaşılabilir tekil.
  locator.registerLazySingleton<OtpGenerator>(() => const OtpGenerator());

  // Faz 1+: VaultRepository (secure storage), Faz 2: CryptoService,
  // Faz 3: SupabaseClient wrapper + AuthRepository burada kaydedilecek.
}
