/// Duyurular sunucu deposu — soyutlama (Faz 3 Patch 4).
///
/// `announcements` tablosu (public read; anon+authenticated SELECT). Yalnız OKUNUR.
/// Sunucu şeması DEĞİŞMEZ. **`audience` RLS'te FİLTRELENMEZ** (deklaratif) → client-side
/// filtre ([visibleAnnouncements]). E2E'ye DOKUNMAZ. Realtime YOK → fetch + cache.
library;

import 'dart:io' show Platform;

import 'sync_exceptions.dart';

class Announcement {
  final String id;
  final String title;
  final String body;
  final String audience;
  final DateTime createdAt;

  const Announcement({
    required this.id,
    required this.title,
    required this.body,
    required this.audience,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'audience': audience,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  /// Sunucu/cache satırı → model. Throws [FormatException] on bad data.
  static Announcement fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final title = json['title'];
    final body = json['body'];
    final createdRaw = json['created_at'];
    if (id is! String) {
      throw FormatException('announcements.id String bekleniyordu (${id.runtimeType})');
    }
    if (title is! String) {
      throw FormatException('announcements.title String bekleniyordu (${title.runtimeType})');
    }
    if (body is! String) {
      throw FormatException('announcements.body String bekleniyordu (${body.runtimeType})');
    }
    if (createdRaw is! String) {
      throw FormatException('announcements.created_at String bekleniyordu (${createdRaw.runtimeType})');
    }
    final created = DateTime.tryParse(createdRaw);
    if (created == null) {
      throw FormatException('announcements.created_at parse edilemedi: $createdRaw');
    }
    final audience = json['audience'];
    return Announcement(
      id: id,
      title: title,
      body: body,
      audience: audience is String ? audience : 'all',
      createdAt: created.toUtc(),
    );
  }
}

abstract interface class AnnouncementsRepository {
  /// Tüm duyuruları çeker (public read; en yeni önce). Ağ/izin hatası → [SyncError].
  Future<List<Announcement>> fetchAll();
}

/// Client-side audience filtre (RLS filtrelemez): `all` VEYA platform eşleşmesi.
/// [platformOverride] testte enjekte edilir (gerçek Platform yerine).
List<Announcement> visibleAnnouncements(
  List<Announcement> all, {
  String? platformOverride,
}) {
  final platform = platformOverride ?? _currentPlatform();
  return all.where((a) {
    final aud = a.audience.toLowerCase();
    return aud == 'all' || aud == 'flutter' || aud == platform;
  }).toList(growable: false);
}

String _currentPlatform() {
  try {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
  } catch (_) {
    // test host'unda Platform tanımsız olabilir → 'all' dışı eşleşme yok.
  }
  return 'unknown';
}
