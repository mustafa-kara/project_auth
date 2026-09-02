/// Gerçek `SupabaseClient`'ı AĞSIZ sürmek için kayıt tutan sahte HTTP istemcisi.
///
/// `SupabaseClient(url, key, httpClient: ...)` ile birlikte kullanıldığında
/// PostgREST'in GERÇEK istek üretimi (metot, yol, query param, `Prefer` başlığı,
/// JSON gövde) ve GERÇEK yanıt/hata ayrıştırması çalışır — yalnız soket sahtedir.
/// Böylece repository testleri "hangi isteği gönderiyoruz" sorusunu elle yazılmış
/// bir PostgREST taklidine değil, kütüphanenin kendisine sorar.
///
/// **`package:http` importu neden yalnız burada:** `http` bu pakette DOĞRUDAN
/// bağımlılık değil (supabase_flutter üzerinden transitive gelir) ve pubspec'e
/// yeni paket EKLENMEZ. Bu yüzden import tek noktada toplanır,
/// `depend_on_referenced_packages` yalnız bu dosyada bastırılır ve testler http
/// tiplerini hiç görmez: [CapturedRequest] / [FakeHttpResponse] ile konuşurlar.
library;

// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// [RecordingHttpClient]'ın yakaladığı tek istek (http tipleri sızmaz).
class CapturedRequest {
  CapturedRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
  });

  /// 'GET' / 'POST' / 'PATCH' ...
  final String method;
  final Uri url;
  final Map<String, String> headers;

  /// Ham gövde (GET'te boş string).
  final String body;

  /// `/rest/v1/tokens` gibi yol.
  String get path => url.path;

  /// `on_conflict`, `user_id`, `select`, `order` ... (PostgREST filtreleri).
  Map<String, String> get query => url.queryParameters;

  /// Gövdenin JSON karşılığı (boş gövde → null).
  dynamic get json => body.isEmpty ? null : jsonDecode(body);
}

/// Sahte HTTP yanıtı. Varsayılan JSON content-type — PostgREST gövdeyi böyle çözer.
class FakeHttpResponse {
  const FakeHttpResponse({
    this.status = 200,
    this.body = '',
    this.headers = const {'content-type': 'application/json; charset=utf-8'},
    this.reasonPhrase,
  });

  /// [data]'yı JSON'a çevirip döner (satır listesi / PostgREST hata gövdesi).
  factory FakeHttpResponse.json(Object? data, {int status = 200}) =>
      FakeHttpResponse(status: status, body: jsonEncode(data));

  final int status;
  final String body;
  final Map<String, String> headers;
  final String? reasonPhrase;
}

/// İsteği alır, yanıtı üretir. **Fırlatabilir** — ağ kesintisi (SocketException)
/// simülasyonu böyle yapılır.
typedef FakeHttpHandler =
    FutureOr<FakeHttpResponse> Function(CapturedRequest request);

/// Gönderilen her isteği [requests]'e kaydeden, yanıtı [handler]'dan alan istemci.
class RecordingHttpClient extends http.BaseClient {
  RecordingHttpClient([FakeHttpHandler? handler])
    : _handler = handler ?? _emptyJsonArray;

  static FakeHttpResponse _emptyJsonArray(CapturedRequest _) =>
      FakeHttpResponse.json(const <Object?>[]);

  final FakeHttpHandler _handler;

  /// Gönderim sırasına göre yakalanan istekler.
  final List<CapturedRequest> requests = <CapturedRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final captured = CapturedRequest(
      method: request.method,
      url: request.url,
      headers: Map<String, String>.from(request.headers),
      body: request is http.Request ? request.body : '',
    );
    requests.add(captured);

    final response = await _handler(captured);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(response.body)),
      response.status,
      // ŞART: postgrest `response.request!.method`'a bakar; request geçilmezse
      // başarılı yanıtta bile "null check operator" hatası alınır.
      request: request,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
    );
  }
}

/// Testlik `SupabaseClient` — tüm HTTP'si [httpClient] üzerinden gider.
///
/// `autoRefreshToken: false`: gerçek istemci arka planda token yenileme zamanlayıcısı
/// kurar; test host'unda bu bekleyen timer'a dönüşür.
SupabaseClient fakeSupabaseClient(
  RecordingHttpClient httpClient,
) => SupabaseClient(
  'https://fake.supabase.co',
  // `sb_publishable_` öneki: istemci tanımadığı anahtar formatında uyarı loglar.
  'sb_publishable_fake',
  httpClient: httpClient,
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);
