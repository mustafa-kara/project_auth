/// CountdownColors.forRemaining — kritik eşiği MUTLAK saniye (Design.md §3),
/// periyottan bağımsız (review P3: eski `5/30` fraction'ı period≠30'da yanlıştı).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/core/ui/tokens.dart';

void main() {
  const c = CountdownColors.dark;

  group('forRemaining — kritik MUTLAK saniye', () {
    test('son 5sn her periyotta kritik (period 15/30/60)', () {
      for (final period in [15, 30, 60]) {
        expect(c.forRemaining(5, period), c.critical, reason: 'period=$period');
        expect(c.forRemaining(1, period), c.critical, reason: 'period=$period');
      }
    });

    test(
      'period=60: 10sn kritik DEĞİL (eski 5/30 fraction yanlış kritik derdi)',
      () {
        // 10/60 = 0.166 ≤ 5/30=0.166 → eski kod kritik derdi; yeni kod 10>5 → değil.
        expect(c.forRemaining(10, 60), isNot(c.critical));
      },
    );

    test(
      'period=15: 2.5→3sn kritik (eski fraction 3/15=0.2 > 5/30 → kaçırırdı)',
      () {
        // 3/15 = 0.2 > 5/30 → eski kod kritik DEMEZDİ; yeni kod 3≤5 → kritik.
        expect(c.forRemaining(3, 15), c.critical);
      },
    );

    test('warning bandı (son %33 ama >5sn) ve healthy', () {
      expect(c.forRemaining(8, 30), c.warning); // 8/30=0.27 ≤ 1/3, 8>5
      expect(c.forRemaining(20, 30), c.healthy); // bol
    });

    test('period<=0 güvenli (30 varsayar, sıfıra bölme yok)', () {
      expect(c.forRemaining(20, 0), c.healthy);
      expect(c.forRemaining(3, 0), c.critical);
    });
  });
}
