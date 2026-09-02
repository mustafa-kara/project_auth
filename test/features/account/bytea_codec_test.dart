/// ByteaCodec testleri (Faz 3 Patch 2) — bytea ↔ Uint8List tek dönüşüm noktası.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_auth/features/account/data/bytea_codec.dart';

void main() {
  group('ByteaCodec', () {
    test('encode → \\x + lowercase hex', () {
      expect(
        ByteaCodec.encode(Uint8List.fromList([0xde, 0xad, 0xbe, 0xef])),
        r'\xdeadbeef',
      );
      expect(
        ByteaCodec.encode(Uint8List.fromList([0x00, 0x01, 0x0f, 0xff])),
        r'\x00010fff',
      );
    });

    test('encode boş liste → \\x', () {
      expect(ByteaCodec.encode(Uint8List(0)), r'\x');
    });

    test('decode kanonik \\x<hex>', () {
      expect(ByteaCodec.decode(r'\xdeadbeef'), [0xde, 0xad, 0xbe, 0xef]);
      expect(ByteaCodec.decode(r'\x00010fff'), [0x00, 0x01, 0x0f, 0xff]);
    });

    test('decode \\x prefix toleranslı (prefix yoksa da çalışır)', () {
      expect(ByteaCodec.decode('deadbeef'), [0xde, 0xad, 0xbe, 0xef]);
      expect(ByteaCodec.decode(r'\Xdeadbeef'), [0xde, 0xad, 0xbe, 0xef]);
    });

    test('decode boş → boş liste', () {
      expect(ByteaCodec.decode(r'\x'), isEmpty);
      expect(ByteaCodec.decode(''), isEmpty);
    });

    test('round-trip (16B salt, 24B nonce, uzun ciphertext)', () {
      for (final len in [16, 24, 48, 200]) {
        final bytes = Uint8List.fromList(
          List.generate(len, (i) => (i * 37 + 11) & 0xff),
        );
        expect(
          ByteaCodec.decode(ByteaCodec.encode(bytes)),
          bytes,
          reason: 'len=$len round-trip kayıpsız olmalı',
        );
      }
    });

    test('decode tek-haneli uzunluk → FormatException', () {
      expect(() => ByteaCodec.decode(r'\xabc'), throwsFormatException);
    });

    test('decode geçersiz hex → FormatException', () {
      expect(() => ByteaCodec.decode(r'\xzz'), throwsFormatException);
      expect(() => ByteaCodec.decode(r'\xgg11'), throwsFormatException);
    });
  });
}
