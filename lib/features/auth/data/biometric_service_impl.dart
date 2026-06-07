/// [BiometricService]'in gerçek implementasyonu (Patch 5).
///
/// - `local_auth` YALNIZ availability kontrolü (`isAvailable`).
/// - Anahtar materyali (`vault_biometric_key_v1`) **ayrı options'lı + namespace'li**
///   `FlutterSecureStorage`'da OS-keystore erişim kontrolüyle saklanır:
///     iOS: Secure Enclave + `biometryCurrentSet` (biyometri seti değişince geçersiz)
///     Android: `strongBiometricOnly` + `enforceBiometrics` (Keystore'da biyometriye bağlı)
/// - `retrieve()` içindeki `storage.read()` OS biyometri prompt'unu tetikler = GERÇEK GEÇİT.
/// - Android API<28 SDK gate `device_info_plus` ile (enforceBiometrics <28'de exception atar).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../domain/biometric_exceptions.dart';
import '../domain/biometric_service.dart';

class BiometricServiceImpl implements BiometricService {
  static const storageKey = 'vault_biometric_key_v1';

  /// Android API 28 (Android 9) — `flutter_secure_storage` biyometrik Keystore
  /// anahtarı için minimum (`setUserAuthenticationRequired` + AES Keystore).
  static const _minAndroidSdk = 28;

  final LocalAuthentication _localAuth;
  final FlutterSecureStorage _storage;
  final DeviceInfoPlugin _deviceInfo;

  BiometricServiceImpl({
    LocalAuthentication? localAuth,
    FlutterSecureStorage? storage,
    DeviceInfoPlugin? deviceInfo,
  })  : _localAuth = localAuth ?? LocalAuthentication(),
        _storage = storage ?? const FlutterSecureStorage(),
        _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  /// iOS/macOS: Secure Enclave + currently-enrolled biometrics (biyometri seti
  /// değişirse anahtar OTOMATİK geçersiz). passcode = passcode-set zorunlu + cihaza bağlı.
  static const IOSOptions _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.passcode,
    useSecureEnclave: true,
    accessControlFlags: [AccessControlFlag.biometryCurrentSet],
  );

  /// Android: yalnız güçlü biyometri (PIN/pattern reddedilir) + Keystore'da
  /// biyometriye bağlı AES anahtarı. strongBiometricOnly → negativeButton ZORUNLU.
  /// Ayrı namespace → standart vault storage'dan KeyStore alias izolasyonu.
  static const AndroidOptions _androidOptions = AndroidOptions.biometric(
    enforceBiometrics: true,
    biometricType: AndroidBiometricType.strongBiometricOnly,
    storageNamespace: 'vault_biometric',
    biometricPromptTitle: 'Vault kilidini aç',
    biometricPromptSubtitle: 'Devam etmek için biyometrik doğrulama',
    biometricPromptNegativeButton: 'İptal',
  );

  @override
  Future<bool> isAvailable() async {
    try {
      if (!await _localAuth.isDeviceSupported()) return false;
      if (!await _localAuth.canCheckBiometrics) return false;
      final enrolled = await _localAuth.getAvailableBiometrics();
      if (Platform.isAndroid) {
        // Strong-policy: zayıf-biyometri-only cihazda buton görünmemeli.
        if (!enrolled.contains(BiometricType.strong)) return false;
        // SDK gate: enforceBiometrics <API28'de fail eder → buton hiç görünmesin.
        final info = await _deviceInfo.androidInfo;
        if (info.version.sdkInt < _minAndroidSdk) return false;
        return true;
      }
      // iOS/diğer: Face/Touch ID zaten strong → enrolled varsa yeterli.
      return enrolled.isNotEmpty;
    } catch (_) {
      // Availability kontrolünde herhangi bir hata → güvenli taraf: kullanılamaz.
      return false;
    }
  }

  @override
  Future<void> enroll(Uint8List keyBytes) async {
    final encoded = base64Encode(keyBytes);
    try {
      await _storage.write(
        key: storageKey,
        value: encoded,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );
    } on PlatformException catch (e) {
      throw _mapPlatform(e);
    }
  }

  @override
  Future<Uint8List> retrieve() async {
    // storage.read OS biyometri geçidi → gerçek prompt + erişim kontrolü.
    final String? raw;
    try {
      raw = await _storage.read(
        key: storageKey,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );
    } on PlatformException catch (e) {
      throw _mapPlatform(e);
    }
    if (raw == null || raw.isEmpty) {
      // Anahtar yok/geçersizleşti (biyometri seti değişti → invalidation).
      throw const BiometricKeyMissing();
    }
    try {
      return base64Decode(raw);
    } on FormatException {
      throw const BiometricKeyMissing();
    }
  }

  @override
  Future<void> disable() async {
    try {
      await _storage.delete(
        key: storageKey,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );
    } on PlatformException catch (e) {
      // Silme hatası: idempotent olmaya çalış ama gerçek hatayı ilet.
      throw _mapPlatform(e);
    }
  }

  /// OS-gated storage / local_auth platform hatasını domain hatasına eşler.
  /// **NOT (planda açık risk):** `PlatformException.code/message` cihaz/OS sürümüne
  /// göre değişir → bu eşleme gerçek cihazda gözlemlenip sabitlenmeli. Burada en
  /// yaygın imzalara göre defansif eşleme yapılır; tanınmayan → [BiometricStorageError].
  Exception _mapPlatform(PlatformException e) {
    final code = e.code.toLowerCase();
    final msg = (e.message ?? '').toLowerCase();
    final hay = '$code $msg';

    if (hay.contains('cancel') || hay.contains('usercancel') ||
        hay.contains('user_cancel') || hay.contains('systemcancel')) {
      return const BiometricCanceled();
    }
    if (hay.contains('lockout') || hay.contains('locked')) {
      return const BiometricLockout();
    }
    // Anahtar invalidated (biyometri değişti) / bulunamadı / decrypt fail.
    if (hay.contains('invalidat') || hay.contains('keypermanentlyinvalidated') ||
        hay.contains('not found') || hay.contains('no_key') ||
        hay.contains('keystore') && hay.contains('invalid')) {
      return const BiometricKeyMissing();
    }
    if (hay.contains('unavailable') || hay.contains('no_hardware') ||
        hay.contains('nohardware') || hay.contains('not_available') ||
        hay.contains('notavailable') || hay.contains('not_enrolled') ||
        hay.contains('notenrolled') || hay.contains('biometric_unavailable')) {
      return const BiometricUnavailable();
    }
    return BiometricStorageError('${e.code}: ${e.message ?? ''}'.trim());
  }
}
