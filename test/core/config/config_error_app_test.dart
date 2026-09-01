// Yapılandırma hatası ekranı: async main içindeki fail-fast SİYAH EKRAN yerine
// geliştiriciye sebebi gösterir (review [P2]).

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/config/supabase_config.dart';
import 'package:project_auth/main.dart';

void main() {
  testWidgets('başlık + validator mesajı görünür', (tester) async {
    // Gerçek fail-fast metni (main.dart'ta yakalanan hatanın toString'i).
    Object? caught;
    try {
      SupabaseConfig.validate(url: '', publishableKey: '');
    } catch (e) {
      caught = e;
    }

    await tester.pumpWidget(ConfigErrorApp(details: caught.toString()));
    await tester.pump();

    expect(find.text('Yapılandırma hatası'), findsOneWidget);
    expect(find.textContaining('SUPABASE_URL is missing'), findsOneWidget);
    expect(
      find.textContaining('--dart-define-from-file=env/dev.json'),
      findsOneWidget,
    );
  });
}
