# Changelog

Proje ilerleme günlüğü. En yeni en üstte.

## 2026-06-08 (Faz 3 Patch 2 — key_attributes upload/restore)

Kripto **metadatası** (`key_attributes`: KDF parametreleri + KEK/recovery ile zaten-şifreli master
key) sunucuya yedeklenir ve **yeni cihazda geri yüklenir** — E2E garantisi KORUNARAK. Artık kullanıcı
yeni cihazda Supabase'e girip master parolasıyla vault'u açabilir (token'lar henüz gelmez — Patch 3).
**Token sync YOK.** Sunucu şeması DEĞİŞMEDİ. Üç tur plan review + iki tur implementasyon review (Codex),
her API `.pub-cache`/Context7 kaynağından teyit edilerek. host **257/257 → 293/293**, APK debug build OK.

- **Yalnız zaten-şifreli metadata gider:** `encrypted_master_key`/`recovery_encrypted_master_key` +
  KDF `salt/ops/mem` + nonce'lar. **masterKey, KEK, recovery key, açık TOTP secret ASLA sunucuya gitmez.**
  `bmk` (biyometri wrap) da gitmez (cihaz-yerel; sunucu şemasında kolon yok → yeni cihaz yeniden enroll).
- **bytea interop tek noktada (`ByteaCodec`):** PostgreSQL `bytea` ↔ `Uint8List` (`\x`+hex). Lokal
  `EncryptedBlob` nonce+ciphertext'i BİRLİKTE tutar; sunucu AYRI kolonlar → upload'ta blob İKİYE bölünür,
  restore'da iki kolondan kurulur. bytea JSON-body INSERT formatı cihazda doğrulanacak açık risk → tek
  dosyada izole (gerekirse oradan düzeltilir; şema değişmez).
- **Restore (yeni cihaz):** `VaultLockCubit.bootstrap` lokal attrs yoksa sunucudan çeker. **Fetch
  BAŞLAMADAN ÖNCE `restoring` state** → router `/splash` (spinner), **kullanıcı `/setup` GÖRMEZ** (fetch
  bitmeden yeni vault kuramaz → çift-vault önlenir). remote VAR → lokale yaz + `locked` (master parola
  sorulur); gerçek 0-row → `uninitialized` (setup); **ağ/RLS hatası → ayrı `restoreFailed` ekranı**
  (`/auth/restore-failed`: tekrar dene + hesap değiştir; parola/recovery/biyometri YOK) — `uninitialized`'a
  DÜŞMEZ (yanlış parola kurup sunucu vault'unu çakıştıramaz). `SyncError` ile gerçek 0-row KESİN ayrılır.
- **Upload (backfill):** vault `unlocked` olunca (unlock/recover/commitSetup) `VaultLockCubit` içinde
  best-effort guard'lı insert: sunucuda kayıt VARSA üzerine YAZMA (server-wins; changePassword çok-cihaz
  senkronu KASITLI olarak Patch 3 `updated_at` LWW'ye ertelendi). Best-effort: kullanıcıyı bloklamaz, hata sessiz.
- **Router guard (review [P1] location-kaybı fix):** `sessionGuard` signedIn dalında özel vault statüleri
  (`restoring`/`restoreFailed`/`keyAttributesCorrupted`) `splash`/auth rewrite'ından ÖNCE GERÇEK `location`
  ile ele alınır → hedefteyken `null` (redirect-loop yok). Yan fayda: mevcut `keyAttributesCorrupted`'ın
  da aynı latent location-kaybı bug'ı kapandı.
- **Regresyon yok:** `VaultLockCubit.remoteRepo`/`uid` NULLABLE → legacy/uid-siz vault ve Patch 1 testleri
  eski davranışı birebir korur (restore/upload no-op). uid prefix'ten türetilir (`'<uid>/'`→`'<uid>'`; boş→null).
- **Restore lokal-finalize hatası (review-sonrası [P2] fix):** remote fetch başarılı ama `attrsStore.write`
  (Keychain/Keystore IO) fırlarsa, eskiden hata `bootstrap` future'ından kabarıp state `restoring`'te asılı
  kalırdı (router `/splash`'te takılır, retry yok). `_restoreFromRemote` artık `SyncError` DIŞI beklenmeyen
  hataları da `restoreFailed`'a çevirir (güvenli + retry edilebilir; `/setup`'a düşmez, unhandled future yok).
- Yeni testler: `bytea_codec_test`, `supabase_key_attributes_repository_test` (mapping round-trip + bmk
  gönderilmez), `vault_lock_cubit_test` (+restore 9 senaryo: fetch-pending→`restoring`, ağ→`restoreFailed`,
  retry, upload-guard), `restore_failed_page_test` (parola/recovery YOK), `guard_test` (+restoring/restoreFailed
  + location-kaybı regresyon). **293/293 host, analyze temiz, APK debug build OK.** Gerçek bytea ağ akışı = manuel checklist.

## 2026-06-08 (Faz 3 Patch 1 — Supabase kimlik / auth)

Uygulamaya **kimlik katmanı** eklendi (Supabase email/parola): kayıt/giriş/çıkış + e-posta onayı.
Vault E2E akışı (master parola/unlock/biyometri) **iç mantığı korunarak** en dışına bir kimlik
kapısı eklendi. **Sync YOK** (Patch 2–3). On iki tur dış review (Codex), her API `.pub-cache`/
Context7 kaynağından teyit edilerek tasarlandı. host **220/220 → 257/257**, APK debug build OK.

- **İki bağımsız "kapı" (sıralı):** Supabase oturumu (kimlik) → vault kilidi (E2E). Birleşik guard
  kimlik kapısını EN DIŞTA tutar; vault guard (masterKey gerektiren shell) yalnız `signedIn &&
  !linkRequired` dalında. `unknown` boyunca `/splash` (vault shell `signedIn` öncesi render edilmez
  → `masterKey` crash'i yok). Login parolası ≠ master parola; birbirini **türetmez**.
- **`SessionCubit`** + `SupabaseAuthRepository`: `signUp`/`signInWithPassword`/`signOut`;
  `onAuthStateChange` **`onError` ZORUNLU** (gotrue ağ hatasını stream error olarak verir → yoksa
  app crash). `AuthException.code` → domain hatalarına map (`email_not_confirmed`/`invalid_credentials`/
  `email_exists`/`weak_password`, kaynaktan teyitli).
- **E-posta onayı ZORUNLU** (PKCE + deep-link `dev.mustafakara.projectauth://login-callback`):
  Android intent-filter (VIEW+DEFAULT+BROWSABLE) + iOS `CFBundleURLTypes`. `emailConfirmPending`
  PERSIST edilir (`auth_pending_email_v1`) — yeniden açılışta onay ekranına döner; "Farklı e-posta
  kullan" pending'i temizleyip çıkışı sağlar (guard trap önlenir).
- **signOut güvenliği:** lokal vault volatile temizliği (`VaultLockCubit.onAuthSignedOut`) network
  signOut'tan ÖNCE — setup/unlock/biometric dahil HER aşamada masterKey/mnemonic silinir
  (`lock()` `setupPending`'de no-op olduğu için ayrı genel metot; commit-in-flight kuralı `:400`'le
  aynı). **`SignOutScope.global`** (kullanıcı kararı — sunucuda tüm cihaz refresh-token'ları revoke);
  ağ hatasında BİLE `signedOut`'a ulaşılır (gotrue local token'ı önce siler — #683; offline garantisi).
- **Onaysız e-posta ile GİRİŞ (review-sonrası [P2] fix):** `signIn` `AuthEmailNotConfirmed`'da pending
  email'i PERSIST eder + `emailConfirmPending` emit → `/auth/confirm` ekranı email'i dolu görür, resend
  çalışır (önceki halde email=null → resend no-op + kullanıcı sıkışırdı).
- **Per-uid view mode (review-sonrası [P3] fix):** `VaultPage` artık global singleton yerine ShellRoute'un
  sağladığı (aktif uid namespace'li) `ViewModeStore`'u `context.read` ile okur (standalone/test fallback
  global). A kullanıcısının kart/liste tercihi B'ye yansımaz; namespaced reset view-mode'u da temizler.
- **Root oturum dinleyicisi sahipliği (review-sonrası [P3] fix):** `main`'deki `SessionState` aboneliği
  artık `StreamSubscription` field'ında tutulur + `dispose`'ta cancel + `onError` ile async hata yolu
  korunur (zone'a sızma yok). Önceki halde anonim listener sahiplenilmiyordu (sızıntı + crash riski).
- **uid namespace izolasyon önceliği (review-sonrası [P3] fix):** uid değişiminde `main._onSession`
  ÖNCE bellekteki vault stack'i doğru uid namespace'ine geçirir, SONRA aktif uid'i persist eder
  (best-effort). `setActive` (secure storage) fail etse bile kullanıcı doğru namespace'te kalır —
  legacy `''` stack'inde sessizce KALMAZ (yanlış vault sızıntısı önlenir); persist sonraki açılışta yeniden denenir.
- **Multi-vault per uid:** her Supabase uid için AYRI lokal vault namespace (`'<uid>/'` prefix;
  store'lar `keyPrefix` alır, boş = Faz 2 byte-identical). `vault_active_uid_v1` (aktif uid) +
  `legacy_link_decided/<uid>` (per-uid karar). İlk login'de uid-siz Faz 2 vault varsa **açık
  account-linking onayı** (`/auth/link`): "ilişkilendir" (taşı + `bmk` TEMİZLE + `biometric.disable`
  → yeniden enroll) / "yeni boş vault". Her iki seçim de kararı işaretler → `linkRequired` düşer
  (guard döngüsü yok). `linkRequired` SENKRON `SessionState` alanı (guard async storage okumaz).
- **Config:** `String.fromEnvironment` + dev fallback (PROJECT_INFO ile hizalı); `publishableKey`
  (anon, RLS arkasında). `sb_secret_` asla client'ta. Sunucu şeması değişmedi (bytea; hex codec Patch 2+).
- Yeni testler: `session_cubit_test` (+linkRequired hydrate köprüsü, signOut-throw, onError, cancel),
  `sessionGuard` grubu, `onAuthSignedOut` grubu (commit-in-flight dahil), `multi_vault_namespace_test`,
  `auth_pages_test`. **257/257 host, analyze temiz, APK debug build OK.**

## 2026-06-08 (Faz 2 Patch 5 — biyometrik vault unlock)

Biyometrik unlock kısayolu eklendi — **E2E parola modelini zayıflatmadan**. masterKey
her zaman parola + recovery key ile de açılır; biyometri yalnız 3. bir wrap yolu açar.
Beş tur dış review (Codex) + her API `.pub-cache` kaynağından teyit edilerek tasarlandı
(körü körüne kabul yok). host **186/186 → 219/219**, integration +3.

- **Güvenlik sınırı = OS keystore erişim kontrolü** (`local_auth` bool'u DEĞİL).
  `biometricKey` (32-byte rastgele) masterKey'i `masterkey-biometric|1` AAD'siyle sarar →
  `KeyAttributes.biometricEncryptedMasterKey` (opsiyonel `bmk` alanı; mevcut vault'lar
  byte-identical, sürüm bump yok). Ham `biometricKey` `vault_biometric_key_v1`'de **ayrı
  options'lı/namespace'li** secure storage'da biyometrik erişim kontrolüyle:
  - **iOS:** `useSecureEnclave: true` + `AccessControlFlag.biometryCurrentSet` →
    biyometri seti değişince anahtar OTOMATİK geçersiz (parolayla aç + yeniden enroll;
    token kaybı yok).
  - **Android:** `AndroidOptions.biometric(enforceBiometrics: true,
    strongBiometricOnly)` → Keystore'da yalnız güçlü biyometriye bağlı (PIN/pattern
    reddedilir); `strongBiometricOnly` → `biometricPromptNegativeButton` zorunlu.
- **Gerçek prompt = `storage.read()` OS geçidi** (TEK prompt). `local_auth` yalnız
  availability kontrolü → **çift prompt yok** (reviewer 2.tur). `biometricKey` byte'ları
  Dart'ta ASLA cache'lenmez; kullanımdan sonra `fillRange(0)`.
- **State modeli:** `biometricEnrolled` (attrs.bmk) + `deviceBiometricAvailable` (cihaz
  yeteneği, enrollment'tan bağımsız) AYRI tutulur — UnlockPage butonu ikisinin kesişimi,
  Settings enable switch'i `deviceBiometricAvailable`'a bakar (yoksa yeni kullanıcı hiç
  açamazdı — reviewer 3.tur deadlock). TÜM `locked`/`unlocked` emit'leri merkezi
  `_locked()`/`_unlocked()` helper'larıyla bu alanları korur (reviewer 4.tur).
- **Atomiklik:** `enableBiometric` OS-key-yaz → attrs-yaz sırası; attrs.write fail →
  `biometric.disable()` ile orphan OS key temizle + state değişmez. `biometricUnlock`
  `KeyMissing` → `bmk` PERSIST temizlenir (bootstrap döngüsü önleme); write fail →
  UI'da kapalı göster (döngü yok). `resetVault` + `disableBiometric` açıkça
  `BiometricService.disable()` çağırır (ayrı namespace → default `_deleteKeys` yetmez).
- **Lifecycle:** biyometri sistem prompt'unun ürettiği `inactive` (`_biometricPromptInFlight`)
  başarılı unlock'u abort ETMEZ; `paused` (gerçek arka plan) yine kesin abort. `main.dart`
  `paused`/`inactive`'i ayrı iletir.
- **Android API<28:** `device_info_plus` ile `sdkInt >= 28` gate (`getAvailableBiometrics`
  SDK'yı gate etmez; `enforceBiometrics` <28'de native exception atardı — reviewer 4.tur).
- **Native:** `MainActivity` → `FlutterFragmentActivity`, `AndroidManifest` `USE_BIOMETRIC`,
  `styles.xml`+`values-night/styles.xml` `Theme.AppCompat.DayNight.NoActionBar` (local_auth
  Android 8 crash önleme), iOS `NSFaceIDUsageDescription`. `flutter build apk --debug` geçti.
- **[P2 review düzeltmesi] Settings switch:** `enrolled && !deviceAvailable` (biyometri
  seti değişti/lockout) durumunda switch tamamen pasifti → kullanıcı Settings'ten
  KAPATAMIYORDU. Yorum doğru invariant'ı yazıyordu ama `onChanged: !deviceAvailable ? null`
  kapatmayı da kilitliyordu. Fix: açma cihaz uygunsa, **kapatma availability'den bağımsız**
  (`enrolled || deviceAvailable`). +1 test (enrolled+unavailable → kapatılabilir).
- **Doğrulama:** `flutter analyze` temiz · host 220/220 · integration 12/12 · `flutter build
  apk --debug` geçti · `BiometricServiceImpl` (gerçek OS/local_auth) cihaz ister → manuel
  checklist [docs/CRYPTO.md §11].

## 2026-06-07 (Faz 2 Patch 4 — commitSetup write-fail atomikliği, 3. tur)

- **[P2] `commitSetup()` `_attrsStore.write()` fail + background.** Önceki tur migration-fail
  yolunu kapatmıştı ama `write()` ayrı bir async noktaydı: write fail ederse kod migration
  catch'ine HİÇ girmeden `finally`ye düşüyor, `finally` yalnız `_commitInFlight=false`
  yapıyordu → `_masterKey`/`_pendingAttrs`/`setupPending` canlı kalıyordu. Bu sırada app
  background olmuşsa (commit in-flight olduğu için `onAppBackgrounded` `cancelSetup`
  çağırmaz) masterKey arka planda bellekte kalırdı (ARCHITECTURE §2.3 ihlali). **Fix:**
  `write()` ayrı `try/catch` ile sarıldı → write fail'de key dispose + pending temizle +
  `uninitialized` (write fail = diske HİÇBİR ŞEY yazılmadı → vault kurulmadı → migration-fail'in
  aksine doğru state `uninitialized`, `locked` değil) + rethrow. Artık commitSetup'ın her
  async çıkışında (write-fail / migration-fail / background-abort / başarı) key garanti
  ele alınıyor.
- **[P3] Tam kesişim regresyon testi.** İlk write-fail testi yalnız cleanup'ı doğruluyordu
  ama background çağrısı YOKTU; mevcut background testi ise write BİTTİKTEN sonra `_migrate`'te
  bekletiyordu — yani "`write()` askıdayken background, SONRA write fail" tam kesişimi test
  edilmemişti. `FakeSecureStorage`'a `writeGate` (Completer) eklendi: write `_attrsStore.write()`'ta
  asılıyken `onAppBackgrounded()` tetiklenir, sonra write throw eder. Beklenen davranış
  doğrulandı — write-fail cleanup (uninitialized + dispose) kazanır; `_commitInFlight=true`
  olduğu için `onAppBackgrounded` `cancelSetup` çağırmaz, temizlik tek yoldan (write catch)
  yapılır.
- **Doğrulama:** `flutter analyze` temiz · host **186/186** (+1: commitSetup write-fail →
  uninitialized + dispose; +1: write-askıda-background kesişim regresyonu) · integration
  **34/34** · `git diff --check` temiz.

## 2026-06-07 (Faz 2 Patch 4 — lifecycle lock kenar durumları, 2. tur)

Bir önceki lifecycle turunda kapatılmayan üç kenar durum (review, kaynaktan doğrulandı):

- **[P1] `beginSetup()` arka-plan yarışı.** `KeyManager.setup()` (Argon2id/KEK) sürerken
  app background olursa `onAppBackgrounded` (state `uninitialized`) sadece
  `_abortToBackground=true` yapıyordu; `beginSetup` bu bayrağı kontrol etmediği için
  işlem bitince masterKey + mnemonic'i belleğe alıp `setupPending` emit ediyordu →
  arka planda key/mnemonic canlı. **Fix:** `beginSetup` await sonrası bayrağı kontrol
  eder → set ise üretilen key'i dispose + `uninitialized` (persist yok).
- **[P1/P2] `locking` sırasında frame gelmeden background.** İnteraktif `lock()`
  dispose'u post-frame'e atıyor; bu sırada background olursa `onAppBackgrounded`
  `locking` case'inde `break` yapıyordu → frame gelmezse key bellekte kalırdı. **Fix:**
  `locking` case'i artık SENKRON dispose + `locked`. Stale post-frame callback
  status-guard'lı → no-op.
- **[P2] `commitSetup()` migration-fail atomik değildi.** `attrs` yazıldıktan sonra
  `_migrate` fail ederse fonksiyon rethrow ediyor ama `_masterKey`/`_pendingAttrs`/
  `setupPending` kalıyordu; attrs diskteyken kullanıcı "iptal" → `cancelSetup` attrs'ı
  silmiyor → tutarsız "uninitialized ama bootstrap locked". **Fix:** migration-fail
  yolunda da key dispose + pending temizle + `locked` emit (vault GERÇEKTEN kurulu —
  attrs diskte; migration idempotent/commit-marker'lı → sonraki unlock yeniden dener)
  + rethrow (UI hatayı gösterir). Artık `setupPending`'e geri dönülmez → cancel tutarsızlığı yok.
- **[P3] Doküman drift:** OTP_ENGINE.md hâlâ 180/180 diyordu → 184/184.
- **Doğrulama:** `flutter analyze` temiz · host **184/184** (+3: beginSetup background-abort,
  locking-frame-yok senkron dispose, commitSetup migration-fail atomik-locked) · integration
  **34/34** · `git diff --check` temiz.

## 2026-06-07 (Faz 2 Patch 4 — lifecycle lock güvenlik açıkları + doküman/test hizalama)

Review iki lifecycle güvenlik riski buldu (kaynaktan doğrulandı, ikisi de gerçek):

- **[P1] Arka plana geçerken devam eden async unlock/recover/commit sonradan
  `unlocked` emit ediyordu.** Senaryo: kullanıcı "Aç" der, Argon2id/migration sürerken
  app `paused`/`inactive` olur; `onAppBackgrounded()` state'i hâlâ `locked` gördüğü
  için bir şey yapmaz; async işlem bitince app ARKA PLANDAYKEN `unlocked` olurdu (key
  bellekte, vault açık). **Fix:** `_abortToBackground` guard'ı. `onAppBackgrounded`
  `locked`/`uninitialized`/`keyAttributesCorrupted`/`setupPending` görürse bayrağı set
  eder; `unlock`/`recoverWithNewPassword`/`commitSetup` `unlocked` emit etmeden ÖNCE
  bayrağı kontrol eder → set ise key dispose + `locked` (vault açılmaz). `commitSetup`'ta
  attrs zaten yazılmışsa doğru state `locked` (uninitialized değil).
- **[P2] `lock()` master key dispose'unu `addPostFrameCallback`'e bağlıyordu; `paused`'ta
  frame garanti olmadığından key bellekte kalabilirdi.** **Fix:** `lock({bool immediate})`.
  `onAppBackgrounded` `lock(immediate: true)` ile key'i SENKRON dispose eder (güvenlik
  önceliği — ARCHITECTURE §2.3 "arka plana geçince temizlenir"). İnteraktif "Kilitle"
  butonu `immediate: false` → frame'li yumuşak teardown (use-after-free yok) korunur.
- **[P3] Doküman/test hizalama:** PLAN.md/OTP_ENGINE.md eski test sayıları güncellendi
  (host 181/181). `MnemonicGrid` artık `SelectableText` (Design.md §3.2 kontratı +
  textScaler 2.0'da sarılır). Design.md `OtpCard` satırı gerçeğe çekildi (ayrı kopyala
  ikon butonu YOK, tap-to-copy). Recovery grid için textScaler 2.0 overflow test kapısı
  eklendi (Design.md §5).
- **Doğrulama:** `flutter analyze` temiz · host **181/181** (+5: 3 P1 yarış testi —
  unlock/recover/commit background-abort + 1 P2 senkron-dispose/interaktif-lock ayrımı +
  1 recovery textScaler overflow) · `git diff --check` temiz.

## 2026-06-07 (Faz 2 Patch 4 — otomatik reinstall-reset GERİ ALINDI)

Önce iOS'ta "uygulamayı sildim, yine parola soruyor" için bir `FirstRunGuard`
(SharedPreferences ilk-açılış bayrağı) eklenmişti; bayrak yoksa Keychain kalıntısı
silinip temiz setup'a düşülüyordu. **Review P0 release blocker:** tek bir boolean bayrak
"temiz reinstall" ile "bu yamadan ÖNCE kurulmuş mevcut kullanıcı"yı ayırt edemez — her
ikisinde de bayrak yoktur ama Keychain'de gerçek bir vault vardır. Mevcut kullanıcı bu
yamayı alıp ilk kez açtığında bayrak yok kabul edilir → `bootstrap` `VaultStorageKeys.all`
siler → **mevcut kullanıcının vault'u kaybolur.**

- **Karar (kullanıcı):** özellik tamamen geri alındı. `iOS Keychain`'in uygulama
  silinince temizlenmemesi Apple'ın bilinçli kararıdır ve mevcut kullanıcıları riske
  atmadan otomatik tespit edilemez. Veri kaybı riski sıfıra indirildi.
- **Geri alınanlar:** `FirstRunGuard` + testi silindi; `VaultLockCubit`'ten
  `isFreshInstall` kancası + bootstrap'taki wipe kaldırıldı; `main.dart` wiring'i
  geri alındı; `shared_preferences ^2.5.5` bağımlılığı pubspec'ten çıkarıldı.
- **Mevcut yol:** kullanıcı vault'u temizlemek isterse zaten var olan
  **"Vault'u sıfırla"** (çift onaylı, `resetVault()` → 5 anahtar) akışını kullanır.
- **Doğrulama:** `flutter analyze` temiz · host 176/176 (önceki +5 geri alındı).

## 2026-06-07 (Faz 2 Patch 4 — auth ekranları redesign + recovery UX)

Patch 4'ün ilk turunda auth ekranları "işlevsel/cilasız" bırakılmıştı (görsel
redesign yalnız vault/OtpCard'a uygulanmıştı). Bu tur **tüm auth akışı Design.md
diline çekildi** + kritik bir recovery UX sorunu giderildi. Görsel doğrulama:
iOS simulator'da 6 ekran × dark/light render edilip screenshot ile teyit edildi.

- **Recovery key gösterimi (UX kritik):** 24 kelime eskiden dikey `ListTile`
  listesindeydi → kullanıcı tek ekranda hepsini göremiyor, yarısını yazıp
  "yazdım" checkbox'ına basıp ilerleyebiliyordu. Yeni `MnemonicGrid`: **2 sütun ×
  12 satır numaralı grid** (sol 1–12, sağ 13–24), GeistMono kelimeler → 24'ü tek
  ekranda görünür. Kopyala butonu + "24 kelimeyi yedekledim" onayı (işaretlenmeden
  Devam pasif). Doğrulama davranışı (3 kelime + 3 deneme limiti) DEĞİŞMEDİ — kullanıcı kararı.
- **"Panoya kopyala" numaralı format:** eskiden `words.join(' ')` → sadece kelimeler,
  sıra numarası yok (yapıştırınca kullanıcı hangi kelime kaçıncı bilemiyordu). Artık
  `1. lizard\n2. goddess ...` (her satır numaralı). `RecoveryUnlockPage` giriş ayrıştırma
  da sağlamlaştırıldı: numaralı yedek formatı yapıştırılırsa sıra öneki (`12.`/`12)`/`12-`)
  ayıklanır → kullanıcı kopyaladığı key'i doğrudan geri yapıştırabilir; düz boşluklu giriş
  de çalışır (regresyon testli).
- **Paylaşılan auth UI katmanı** (`lib/core/ui/widgets/`): `AuthScaffold` (ikon +
  başlık[headlineSmall] + açıklama[onSurfaceVariant] + kaydırılabilir gövde + sabit
  alt CTA; safe-area + tutarlı `Gap` spacing + dynamic-type taşma yok), `AppTextField`
  (görünür label + show/hide + inline hata + helper), `MnemonicGrid`, `auth_bits`
  (AuthErrorText + BtnSpinner). `app_theme`'e `monoWord` (GeistMono recovery kelimesi).
- **6 auth ekranı yeniden yazıldı:** setup_password, recovery_show, recovery_verify,
  recovery_unlock, unlock, auth_integrity → hepsi `AuthScaffold`/`AppTextField`,
  token'lar, Geist tipografi, tek birincil CTA (Design.md §3/§4). "cilasız sürüm"
  yorumları kalktı.
- **vault_page state-view'ları + scan_page:** `_EmptyView`/`_NoMatchView`/
  `_IntegrityErrorView` + arama padding token'lara çekildi; `_ScanError` token +
  textTheme (ham `Colors.grey`/sabit spacing kalktı; reticle overlay rengi bilinçle korundu).
- **Doğrulama:** `flutter analyze` temiz · host 176/176 (regresyon yok; +3:
  recovery_unlock numaralı-parse + düz-giriş, recovery_show numaralı-kopyala) · iOS
  simulator görsel doğrulama (6 ekran, dark+light). `recovery_verify_page_test`
  davranışı korundu (TextFormField → TextField render'ı `find.byType` ile eşleşir).

## 2026-06-07 (Faz 2 Patch 4) — Setup/Unlock UI + oturum kilidi + UI/UX redesign

Vault artık gerçek bir kilit/oturum akışına sahip ve tüm arayüz tek tutarlı tasarım
dilinde ("Precision/Technical"). Önce `docs/Design.md` ile sınırlar kilitlendi, sonra
güvenlik çekirdeği → corruption UI → görsel redesign sırasıyla uygulandı (regresyon
izolasyonu). **Host testleri 122 → 173/173.** Tüm bulgular kaynaktan doğrulandı.

- **`docs/Design.md`:** tasarım dili, token'lar, bileşen envanteri, erişilebilirlik
  kontratı, asset lisansları (Geist OFL 1.1, simple-icons CC0 — kaynaktan teyit).
- **Oturum çekirdeği:** `VaultLockCubit` durum makinesi (`uninitialized`/`setupPending`/
  `locked`/`unlocked`/`locking`/`keyAttributesCorrupted`) + tek key-sahiplik modeli
  (lock: `locking`→subtree teardown→`masterKey.dispose()`→`locked`; use-after-free yok).
  `KeyAttributesStore` (malformed→`keyAttributesCorrupted`, sızıntı yok). Setup commit
  **recovery doğrulanmadan persist YOK**; recover+yeni parola tek atomik çağrı.
- **Router:** `createAppRouter`→`AppRouterBundle` + kendi `CubitRefreshNotifier` adapter'ı
  (**go_router 17.3.0'da `GoRouterRefreshStream` YOK** — kaynaktan teyit; CHANGELOG:693).
  refreshListenable dispose'u kök widget'ta (go_router dispose etmez). Guard tüm state'leri
  kapsar; `ShellRoute` unlocked subtree'de `VaultCubit`'i sağlar (scan/add yalnız orada).
- **Lifecycle lock:** `paused` VE `inactive` → unlocked kilitlenir, setupPending temizlenir.
- **Corruption/integrity UI:** VaultPage `corruptedCount` banner'ı (Yine de devam et /
  onaylı kaldır) + `VaultIntegrityException` integrity ekranı (boş-durum DEĞİL) +
  `/auth-integrity` (Yeniden dene / Vault'u sıfırla) + `resetVault()` (5 anahtar siler;
  plaintext+marker dahil → yeniden migrate edilmez).
- **UI/UX redesign:** Geist + GeistMono **gömülü** (runtime fetch yok; Türkçe glif teyitli;
  `google_fonts` KULLANILMAZ), güven-mavi palet + `CountdownColors` `ThemeExtension`,
  `CountdownRing` (yeşil→amber→kırmızı + ortada saniye, <5sn pulse, reduced-motion'da kapalı),
  `IssuerAvatar` (simple-icons CC0 curated 27 ikon + baş-harf fallback), `OtpCard` (kart/liste
  varyant + tap-to-copy + Semantics), kart/liste toggle (`vault_view_mode_v1` secure_storage),
  ScanPage köşe-rehberli reticle.
- **Erişilebilirlik kapısı:** Semantics (kod + kalan süre), textScaler 2.0 taşma yok,
  reduced-motion çökme yok — widget testleriyle.
- **DI/main:** global `VaultCubit` kaldırıldı; kök `StatefulWidget` `VaultLockCubit` + router
  bundle'ı tutar, lifecycle gözler, `bundle.refresh`'i dispose eder.
- **Patch 4 sertleştirme (review turu — 6 bulgu, hepsi kaynaktan doğrulandı):**
  - **(P1) masterKey migration-fail lifecycle:** `unlock`/`recoverWithNewPassword` artık
    masterKey'i ancak migration BAŞARIYLA bittikten sonra sahipleniyor; migration fırlatırsa
    key `finally`'de dispose edilir, `unlocked`'a geçilmez ("locked state'te canlı key"
    invariant'ı korunur).
  - **(P1) guard setup alt-rotaları:** `uninitialized` iken yalnız `/setup` (recovery-show/
    verify alt rotaları engellenir) — mnemonic henüz yokken `/setup/verify`'a deep-link
    `RangeError` üretiyordu. Alt-ağaç yalnız `setupPending`'de açık.
  - **(P2) setup restart:** `beginSetup` önceki pending masterKey'i dispose ediyor (üzerine
    yazıp sızdırmıyor).
  - **(P2) recovery-verify deneme limiti:** yanlış kelimede artık inline hata + kalan deneme;
    3 yanlıştan sonra `cancelSetup()` (pending key dispose). Sınırsız bellekte asılı kalmaz
    ama tek yazım hatası setup'ı baştan yaptırmaz (kullanıcı kararı).
  - **(P2) integrity ekranı reset:** toptan-bozuk `_IntegrityErrorView`'a çift-onaylı
    "Vault'u sıfırla" son çaresi eklendi (AuthIntegrityPage ile aynı kalıp).
  - **(P3) CountdownRing kritik eşiği:** `forFraction(5/30)` → `forRemaining(remaining, period)`
    MUTLAK saniye; period≠30'da doğru (period=60'ta son 5sn kritik, 10sn değil; period=15'te
    3sn kritik). Design.md ile hizalandı.
- **Patch 4 sertleştirme (2. review turu — 3 bulgu, hepsi kaynaktan doğrulandı):**
  - **(P1) load-bitmeden-mutasyon veri kaybı:** `VaultCubit` mutasyonları (add/remove/
    increment/purge) artık ilk `load()` tamamlanana kadar **bekler** (`Completer` ile).
    Önceki `_mutatedBeforeLoad` merge'i yalnız belleği düzeltiyordu; load bitmeden `save()`
    edilirse diskteki henüz-okunmamış şifreli kayıtlar EZİLİYORDU (`_lastById`/`_corruptedRaw`
    boşken yazma). `load()` ayrıca idempotent (tek ilk-yükleme).
  - **(P2) lifecycle lock güvenli sıra:** `onAppBackgrounded` artık `unlocked`'ta doğrudan
    `lock()`'a delege ediyor (locking → subtree teardown → post-frame `masterKey.dispose()`).
    Eskiden hemen dispose ediyordu → repo async encrypt/decrypt yaparken disposed `SecureKey`'e
    use-after-free riski. `setupPending` → `cancelSetup` (tüketici yok, hemen güvenli).
  - **(P3) integrity reset testi:** toptan-bozuk integrity ekranındaki çift-onaylı
    "Vault'u sıfırla" → `resetVault()` akışı widget testiyle kapatıldı (data-destructive).
- **Patch 4 sertleştirme (3. review turu — 1 bulgu, kaynaktan doğrulandı):**
  - **(P1) integrity state'te ekleme = onaysız overwrite:** Toptan bozulma (top-level
    malformed/non-list veya tüm-kayıt decrypt-fail) `load()`'ı erken fırlatır → `state.error`
    set, `accounts` boş, repo cache (`_corruptedRaw`/`_lastById`) BOŞ. Bu state'te `VaultPage`
    integrity ekranını gösterirken **FAB hâlâ aktifti** → manuel/QR ekleme `VaultCubit.add` →
    `save()` çalışır ve boş cache'le yalnız yeni token'ı yazıp **diskteki bozuk-ama-belki-
    kurtarılabilir ham vault'u kullanıcının açık "Vault'u sıfırla" onayı OLMADAN ezerdi.**
    Çift katman düzeltme: (a) **`VaultCubit` `_guardIntegrity()`** — `state.error != null` iken
    add/remove/increment `StateError` fırlatır (UI `_runMutation`/`_addAndClose` yakalar →
    SnackBar); (b) **VaultPage FAB** integrity state'inde gizli (`integrityBlocked`). +3 test.
- **Doğrulama:** `flutter analyze` temiz, host 173/173, `flutter build apk --debug` +
  `flutter build ios --debug --no-codesign` geçti. Asset delta ~912KB raw (curated; lean).

## 2026-06-07 (Faz 2 Patch 1–3) — E2E kripto katmanı + şifreli lokal vault

Faz 2'nin çekirdeği: vault artık offline çalışıyor **ama düz JSON değil, E2E şifreli**.
Her patch çok-turlu dış review'dan geçti; **tüm bulgular kaynaktan (Context7/pub.dev/
kurulu paket kaynağı) doğrulandı** (standing rule) — bazı makul-ama-yanlış iddialar elendi
(sodium sürümü, `runIsolated` arity). UI/route/DI rewiring + biyometri Patch 4–6'da.

- **Patch 1 — `core/crypto/`:** `CryptoService` (soyut) + `SodiumCryptoService` (SodiumSumo).
  XChaCha20-Poly1305 IETF (AAD'li) + Argon2id (KEK, **ayrı isolate** — UI bloklamaz).
  `EncryptedBlob`/`KeyHandle` (opaque, `SecureKey` sızmaz) + `crypto_exceptions`.
  **Sürüm kararı:** `sodium 3.4.6 + sodium_libs 3.4.6+4` — sodium 4.x Dart 3.11+ ister,
  proje Dart 3.10.7. Detay [docs/CRYPTO.md](docs/CRYPTO.md).
- **Patch 2 — anahtar hiyerarşisi:** `KeyManager` (setup/unlock/recoverUnlock/changePassword,
  hepsi Future, ara key'ler `finally`'de dispose/zero-fill). `KeyAttributes` value object.
  **Kendi BIP39 impl'imiz** (kanonik paket bakımsız → güven sınırına sokulmadı): resmi 2048
  kelime (MIT, SHA-256 teyitli), 256-bit, checksum doğrulamalı; resmi Trezor vektörleriyle test.
  Domain parola politikası (`WeakPasswordException`, min 8).
- **Patch 3 — şifreli vault + migration:** `EncryptedVaultRepository` (token-bazlı record
  `{id,v,n,c,updatedAt,deleted}`, AAD `token|1|<id>`, **unchanged-blob koruması**,
  **bozuk-kayıt koruması** — scalar/null dahil, **integrity exception** ile sessiz veri
  kaybı yok). `VaultMigration` (Faz 1 plaintext → şifreli, commit-marker idempotency,
  **id-bazlı upsert** — crash sonrası var olanı ezmez). `VaultRepository` arayüzü genişledi
  (`load()→VaultLoadResult`, `purgeCorrupted()`). Raw-storage güvenlik testi:
  secret/issuer/accountName ciphertext dışında **hiç** görünmüyor.
- **Sıkı validasyon (review):** `EncryptedBlob`/`KeyAttributes` parse'ı bozuk/ileri-sürüm
  metadata'yı sodium'a ulaşmadan reddeder (nonce=24B, ciphertext≥16B, salt=16B, KDF pozitif
  tamsayı, version desteklenen; kesirli `num` sessiz truncate edilmez).
- **Testler:** host **79 → 122** (EncryptedBlob/KeyAttributes JSON+validasyon, BIP39 +
  resmi vektörler, vault corruptedCount). **Integration 34** (cihaz/sim — gerçek libsodium):
  sodium service 8 + KeyManager 8 + encrypted vault/migration 18. `analyze` temiz, APK + iOS
  build geçer. (libsodium testleri `integration_test/`te — `sodium_libs` plain `flutter test`
  VM host'unda yüklenmez.)

## 2026-06-07 (3. tur) — JSON tip-güvenliği + tüm mutasyonlarda hata yönetimi (review)

Dış review 4 bulgu daha verdi (2 orta + 2 düşük); **hepsi kaynaktan doğrulandı, hepsi gerçekti** ve düzeltildi. (Önceki turun add/QR düzeltmeleri kapanmış teyit edildi; bu tur kalan kenar durumlar.)

- **#1 (orta) — `fromJson` cast'leri `TypeError` üretebiliyordu:** `as String?`/`as num?`
  cast'leri `type: 123` / `digits: "6"` gibi bozuk depo verisinde `FormatException` DEĞİL
  `TypeError` atıyordu → `load()`'taki `on FormatException` yakalayamaz, tek bozuk kayıt tüm
  yüklemeyi kırardı. **Düzeltme:** tip-toleranslı `_asString`/`_asInt` yardımcıları (yanlış tip →
  `FormatException`; sayısal String → int esnek). `VaultRepository.load()` artık kayıt başına
  genel `catch` (FormatException dışı da) + anahtar `_coerceStringKeys` ile güvenli.
- **#2 (orta/düşük) — Silme/HOTP sayaç artırma kalıcılık hatasını UI yakalamıyordu:** `onDelete`/
  `onIncrement` `VoidCallback` üzerinden fire-and-forget'ti (add/QR düzelmişti ama bu ikisi geride
  kalmıştı). Save patlarsa kullanıcı başarılı sanır, restart'ta değişiklik geri dönerdi.
  **Düzeltme:** `VaultPage._runMutation(Future, errorPrefix)` — mutasyonu `await` eder, save hatasında
  SnackBar gösterir (bellek-içi state güncel ama yazma başarısızsa bilgilendirir).
- **#3 (düşük) — QR save hatasında `mounted` guard eksikti:** `_onDetect` catch'i `_showError` →
  `context` kullanıyordu; kullanıcı ayrılmışsa disposed context riski. **Düzeltme:** `_showError`
  başına `if (!mounted) return` (add sheet'teki korumayla tutarlı).
- **#4 (düşük) — Doküman drift:** `PLAN.md` CI satırı hâlâ "67/67" diyordu (dosyanın gerisi 75) →
  güncellendi.
- **Testler:** +4 (yanlış-tip type/digits reddi, sayısal-String toleransı, remove/increment save-hata
  fırlatma) + load testine yanlış-tip kayıt senaryoları. **75 → 79, hepsi geçti; `analyze` temiz.**

## 2026-06-07 (2. tur) — Kalıcılık dayanıklılığı + async hata yönetimi (review)

Dış review 5 bulgu verdi (2 orta + 3 düşük); **hepsi kaynaktan doğrulandı, hepsi gerçekti** ve düzeltildi. APK + iOS build'i de geçti (review tarafından).

- **#1 (orta) — JSON yükleme parser validasyonunu bypass ediyordu:** `OtpAccount.fromJson`
  Base32/digits/period/counter kontrolü yapmıyordu → bozuk kayıt `OtpCard` render/timer'da
  (`secretBytes`, `period=0` bölme) crash ederdi. **Düzeltme:** validasyon TEK noktaya çekildi —
  `OtpAccount` ctor artık `validate()` çağırır (secret Base32, digits 6–8/Steam 5, period 1–600,
  counter ≥0). Böylece parse, fromJson ve programatik kurulum aynı güvenlik kapısından geçer;
  geçersiz `OtpAccount` hiçbir yoldan oluşamaz. Ayrıca `VaultRepository.load()` üst-düzey
  `jsonDecode` hatasını da yakalar (eskiden tüm yükleme patlardı) → boş vault'a düşer.
- **#2 (orta) — `add()` future'ı beklenmiyordu:** Manuel/QR ekleme `add()`'i fire-and-forget
  çağırıyordu; `secure_storage` yazma hatası UI'da yakalanmıyordu (kullanıcı "eklendi" sanıp
  restart'ta kaybedebilirdi). **Düzeltme:** `_AddSheet` ve `ScanPage._onDetect` artık `await`
  eder; başarılıysa kapatır, hata olursa formu/taramayı açık bırakıp hatayı gösterir. Ekleme
  sırasında butonlar disable + spinner.
- **#3 (düşük/orta) — Açılış yarış durumu:** `load()` bitmeden kullanıcı ekleme yaparsa geç
  tamamlanan `load()` mevcut state'i eski depo içeriğiyle ezebilirdi. **Düzeltme:** `VaultCubit`
  yükleme-öncesi mutasyonu izler; geç `load()` ezmek yerine depo kaydı + kullanıcı eklemelerini
  id-bazlı **birleştirir** ve yeniden persist eder.
- **#4 (düşük) — Arama temizleme:** `clear` butonu yalnız `_query`'yi sıfırlıyordu; `TextField`
  controller'ı olmadığından ekranda eski metin kalıyordu. **Düzeltme:** `TextEditingController`
  eklendi, temizlemede hem state hem görünen metin sıfırlanır (dispose edilir).
- **#5 (düşük) — Doküman drift:** `PLAN.md` "60/60", `docs/OTP_ENGINE.md` vault'u hâlâ
  "in-memory / sonraki adım" anlatıyordu → güncel duruma (kalıcı vault, tek-nokta validasyon)
  ve test sayısına çekildi.
- **Testler:** +8 (4 JSON validasyon reddi + 3 load dayanıklılık (mocktail ile bozuk JSON/kayıt) +
  save-hatası fırlatma + yarış-durumu merge). **67 → 75, hepsi geçti; `analyze` temiz.**

## 2026-06-07 — Faz 1 kalanı: kalıcılık + QR tarama + arama (+ doküman drift)

Faz 1 tamamlandı. Dış review'ın iki düşük öncelikli doküman drift'i (kaynaktan doğrulandı) düzeltildi, sonra Faz 1'in kalan üç maddesi uygulandı.

- **Doküman drift #1 (düşük) — ARCHITECTURE.md RLS örneği:** §RLS politikaları satırı yalın
  `user_id = auth.uid()` gösteriyordu; canlı/migration `(select auth.uid())` (init-plan
  optimizasyonu) kullanıyor. Kopyalanırsa `auth_rls_initplan` uyarısı dönerdi → örnek
  `(select auth.uid())`'e ve nedeni açıklayan nota güncellendi.
- **Doküman drift #2 (düşük) — PROJECT_INFO.md migration özeti:** `initplan` migration'ı için
  "+ audit FK index" yazıyordu; index aslında init migration'a taşındı, initplan'dan kaldırıldı
  (migration dosyası bunu belgeliyor). Özet düzeltildi.
- **Kalıcılık (secure_storage):** `OtpAccount.toJson/fromJson` (URI'den farklı — `id` + `counter`
  gibi yerel/operasyonel alanları korur, bozuk alan → `FormatException`). `VaultRepository`
  arayüzü + `SecureStorageVaultRepository` (tek JSON anahtarı; bozuk tek kayıt atlanır, tüm
  vault düşmez). `VaultCubit` artık repository alır: açılışta `load()`, her mutasyonda persist;
  no-op'larda gereksiz yazma yapmaz. `loaded` state'i ile ilk yüklemede spinner.
- **QR tarama (`mobile_scanner` 7.2):** `ScanPage` gerçek tarayıcı — `DetectionSpeed.noDuplicates`,
  yalnız `qrCode` formatı, ilk geçerli `otpauth://`'ta çift-ekleme guard'lı pop, geçersiz QR'da
  SnackBar + taramaya devam, flaş/kamera-değiştir, izin-reddi için kullanıcı dostu `errorBuilder`.
  Platform izinleri: iOS `NSCameraUsageDescription`, Android `CAMERA` + `uses-feature camera
  required=false` (manuel giriş hâlâ mümkün).
- **Vault arama:** `VaultPage` AppBar'da arama çubuğu — issuer/hesap/label üzerinde
  case-insensitive filtre; eşleşme yoksa ayrı durum. Ekleme menüsü QR/manuel ayrımı.
- **Testler:** 7 yeni (6 JSON round-trip/dayanıklılık + 1 VaultCubit load); 5 VaultCubit testi
  async repository imzasına uyarlandı (FakeRepo ile persist doğrulaması). **60 → 67, hepsi geçti;
  `analyze` temiz.** API'ler Context7 ile teyit edildi (mobile_scanner v7 `errorBuilder`/
  `MobileScannerErrorCode`, flutter_secure_storage v10 default RSA-OAEP+AES-GCM).

## 2026-06-06 (5. tur) — Vault state sağlamlığı + token id + parse sıkılaştırma (review #5)

Dış review 5 bulgu verdi; **hepsi kaynak koddan doğrulandı, hepsi gerçekti** ve düzeltildi.

- **#1 (orta) — OtpCard state reuse'da TOTP timer durabilir:** `VaultPage` kartlara stabil
  `Key` vermiyordu; `OtpCard.didUpdateWidget` tip değişiminde (TOTP↔HOTP) timer'ı
  başlatmıyor/iptal etmiyordu. **Düzeltme:** kartlara `ValueKey(account.id)` + `_syncTimer()`
  (idempotent: zaman-bazlıysa timer başlat, HOTP'te iptal) hem `initState` hem `didUpdateWidget`'te.
- **#2 (orta) — Token'da stabil id yok (ARCHITECTURE §7.5 ile drift):** `OtpAccount`'a uuid v4
  `id` eklendi (verilmezse üretimde atanır). `VaultCubit` artık index yerine **id-bazlı**
  (`removeById`/`incrementCounter(id)`) — liste reorder/eşzamanlı değişimde yanlış öğeye
  dokunmaz. Faz 3 backfill idempotent upsert'ünün temeli. `copyWith` id'yi korur; `props`'a dahil.
- **#3 (orta) — Bilinmeyen `algorithm` sessizce SHA1'e düşüyordu:** `OtpAlgorithm.fromName`
  artık **verilmiş ama desteklenmeyen** algoritmayı (`SHA3`, `md5`, typo) `FormatException`
  ile reddeder; eksik/boş hâlâ SHA1 default. `digits`/`period` ile aynı "verilmişse doğrula" prensibi.
- **#4 (düşük) — ARCHITECTURE.md `sodium_libs` drift'i:** §1 tablosu + paket notu `sodium`
  paketine güncellendi (README/PLAN ile hizalı; `sodium_libs` discontinued uyarısı eklendi).
- **#5 (düşük) — Route diagnostic log kalıcı açıktı:** `debugLogDiagnostics: kDebugMode`
  (yalnız debug build; profile/release sessiz).
- **#6 (orta, takip turu) — HOTP'te `counter` eksikse sessizce 0 kabul ediliyordu:** Repro
  testiyle 0'a düştüğü kanıtlandı. Key URI Format'a göre HOTP'te `counter` **zorunlu** →
  `_parseBounded`'a `required` parametresi eklendi; HOTP'te eksik counter `FormatException`.
  TOTP/Steam'de counter kullanılmadığından eksiklik serbest (0). 3 yeni test.
- **Testler:** 12 yeni test (4 algorithm/id + 5 VaultCubit + 3 HOTP counter zorunluluğu).
  **Toplam 48 → 60, hepsi geçti; `analyze` temiz.** `uuid 4.5.3` eklendi.

## 2026-06-06 (4. tur) — Doküman drift + seed config (review #4)
- Test sayısı drift'i: README/PLAN/OTP_ENGINE'de kalan `38/38`·`39/39` → güncel **48/48** yapıldı.
- `config.toml` `[db.seed]` `enabled=false` (var olmayan `./seed.sql` "no files matched" WARN
  üretiyordu; seed kullanmıyoruz). Lokal `supabase start` ile WARN'ın gittiği doğrulandı.

## 2026-06-06 (3. tur) — OTP input validasyonu + uçtan uca hook doğrulaması

Dış review 2 bulgu daha verdi; ikisi de **reprodüksiyon testiyle ispatlanıp** düzeltildi.

- **#1 (orta) — Malformed otpauth:// UI crash riski:** Repro testi yazıldı ve crash KANITLANDI:
  geçersiz Base32 secret parse'ı geçiyordu ama `secretBytes` (kart render) `FormatException`
  fırlatıyordu; `period=0` `secondsRemaining`'de sıfıra bölüyordu. **Düzeltme:** validasyon
  `OtpAuthUri.parse` anına çekildi — secret Base32 decode doğrulanır, `digits` (6–8/Steam 5),
  `period` (1–600), `counter` (≥0) aralık kontrolünden geçer; geçersiz → `FormatException`.
  9 yeni test eklendi. **Test toplamı 39 → 48, hepsi geçti; `analyze` temiz.**
- **#2 (düşük) — Local config'de hook kapalı:** `config.toml`'da `[auth.hook.custom_access_token]`
  etkinleştirildi (`pg-functions://postgres/public/custom_access_token_hook`). Lokal stack
  (GoTrue) ile **gerçek login akışı uçtan uca test edildi**: signup → admin ekle → signin →
  JWT'de `app_metadata.admin=true`; normal kullanıcıda `false` (negatif kontrol). Bu, önceki
  "fonksiyonu doğrudan çağırma" testinden daha güçlü — tam auth pipeline'ı doğrular.

## 2026-06-06 (2. tur) — Dış review #2 düzeltmeleri + fresh-deploy doğrulaması

Dış review 4 bulgu daha verdi; hepsi **lokal Supabase CLI ile gerçek Postgres'te** ele alındı
(Supabase MCP bu oturumda bağlı değildi → `supabase start` ile lokal stack kuruldu).

- **#1 (yüksek) — Fresh deploy fail:** `idx_audit_logs_actor` index'i hem `init` hem `initplan`
  migration'ında oluşturuluyordu → temiz projede 2. migration "already exists" verirdi.
  `initplan` dosyasından duplicate `create index` KALDIRILDI. **Fresh deploy lokalde sıfırdan
  uygulandı, üç migration da hatasız geçti.**
- **#2 (orta) — `supabase_admin` default ACL:** `postgres` owner default'u 0003 ile daraldı ama
  `supabase_admin` owner default'u hâlâ geniş. Lokalde test edildi: migration `supabase_admin`'in
  default privilege'ını DEĞİŞTİREMİYOR ("permission denied" — Supabase kısıtı). Çözüm kod değil
  disiplin → 0003'e kalıcı uyarı eklendi: tablolar yalnız `postgres` (migration) ile oluşturulmalı.
- **#3 (orta) — Flutter init API:** Kurulu paket kaynağından kesin doğrulandı
  (`supabase_flutter 2.14.1/lib/src/supabase.dart`): `publishableKey` GERÇEK parametre, `anonKey`
  artık `@Deprecated`. `publishableKey:` hem doğru hem gelecek-uyumlu. PROJECT_INFO güncellendi.
- **#4 (düşük) — Test drift + idempotentlik:** Migration isimleri güncellendi (TEST_REPORT +
  test betiği). Token insert'lerine sabit `id` eklendi; betik 2 kez çalıştırılarak idempotentlik
  fiilen kanıtlandı (2. koşuda da count=1).
- Eklenenler: `supabase/config.toml` (CLI init), `supabase/.gitignore` (`.branches/.temp`).

## 2026-06-06 — Flutter Faz 0/1 çekirdeği + DB sertleştirme

### Flutter — Faz 0 (temel kurulum)
- Flutter projesi oluşturuldu (3.38.6, org `dev.mustafakara`, iOS+Android).
- Feature-first + katmanlı klasör yapısı: `lib/core/{otp,di,router,theme,error,config,storage}`,
  `lib/features/{vault,scan}/...`.
- Bağımlılıklar eklendi ve sürüm çakışmaları çözüldü:
  `flutter_bloc 9.1`, `go_router 17.3`, `get_it 9.2`, `injectable 2.5`, `freezed 3.2`,
  `supabase_flutter 2.14`, `sodium_libs 3.4`, `flutter_secure_storage 10.3`,
  `mobile_scanner 7.2`, `local_auth 3.0`, `crypto`, `equatable`.
- DI composition root (`configureDependencies`, get_it manuel), go_router rotaları,
  Material 3 açık/koyu tema, `main.dart` (BlocProvider + MaterialApp.router).

### Flutter — Faz 1 (OTP çekirdeği)
- `core/otp/`: Base32 (RFC 4648), HOTP (RFC 4226), TOTP (RFC 6238), Steam Guard,
  `OtpAccount` modeli, `otpauth://` parse/serialize.
- **38 RFC test vektörü yazıldı ve çalıştırıldı — hepsi geçti** (HOTP Appendix D,
  TOTP Appendix B SHA1/256/512, Base32, Steam, URI round-trip).
- Vault UI: `VaultCubit` (in-memory), `VaultPage`, geri sayımlı/kopyalanabilir `OtpCard`,
  manuel `otpauth://` ekleme. `ScanPage` placeholder (QR sırada).
- Doğrulama: `flutter analyze` temiz · `flutter test` **39/39** geçti.

### Bilinen sürüm tuzakları (pubspec'te yönetiliyor)
- 🔐 Kripto (Faz 2): `sodium ^3.4.6` + `sodium_libs ^3.4.6+4`. sodium 4.x Dart 3.11+ ister; proje Dart 3.10.7 → 4.x çözülemez (3.x bilinçli karar, pre-built binary, native-assets flag gerekmez). `sodium_libs` "discontinued" etiketli ama 3.x hattı çalışıyor (integration testleriyle kanıtlı). Detay docs/CRYPTO.md.
- `injectable` 2.x'e sabit (generator henüz 3.x desteklemiyor).
- `json_annotation` ^4.9.0'a sabit (4.12 henüz `json_serializable` ile uyumsuz).

### Supabase backend — dış review sonrası düzeltmeler
- **`0003_least_privilege_revoke` migration'ı** (canlıya uygulandı): `pg_default_acl`
  kaynaklı fazlalık `anon`/`authenticated` table privilege'ları revoke edildi
  (RLS + table-grant iki katman). Revoke sonrası security advisor yine **0 uyarı**.
- **Migration history hizalandı:** yerel tek squashed `0001` → canlıyla birebir 3
  timestamp'li dosya + `supabase/migrations/README.md`.
- **Doküman drift'leri düzeltildi:** `unused_index` 3→1 (gerçek advisor çıktısı),
  `db push` uyarısı (mevcut canlı projeye tekrar push etme), migration listeleri.
- Reddedilen 2 review bulgusu (doğrulanarak): `publishableKey` parametresi gerçek ve
  compile'da takılmaz (Context7 Dart upgrade-guide); test idempotency teorik/düşük.

## Öncesi — Mimari & Backend (özet)
- Çok turlu review + doğrulamayla olgunlaşan tam mimari (ARCHITECTURE.md).
- Supabase `authenticator-dev` projesi: 8 tablo + RLS + Custom Access Token Hook +
  private admin aggregate. Uçtan uca güvenlik testi 8/8 geçti (TEST_REPORT.md).
