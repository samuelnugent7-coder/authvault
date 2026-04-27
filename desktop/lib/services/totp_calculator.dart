import 'dart:math';
import 'dart:typed_data';
import 'package:base32/base32.dart';
import 'package:crypto/crypto.dart';

/// Pure-Dart TOTP calculator.
/// Supports SHA1 (hashAlgo=0), SHA256 (1), SHA512 (2).
class TotpCalculator {
  static String generate({
    required String secret,
    required int duration,
    required int length,
    required int hashAlgo,
    DateTime? now,
  }) {
    final time = now ?? DateTime.now();
    final counter = time.millisecondsSinceEpoch ~/ 1000 ~/ duration;
    return _hotp(secret: secret, counter: counter, length: length, hashAlgo: hashAlgo);
  }

  static int secondsRemaining({required int duration, DateTime? now}) {
    final t = now ?? DateTime.now();
    final elapsedInPeriod = (t.millisecondsSinceEpoch ~/ 1000) % duration;
    return duration - elapsedInPeriod;
  }

  static double progress({required int duration, DateTime? now}) {
    final t = now ?? DateTime.now();
    final elapsed = (t.millisecondsSinceEpoch ~/ 1000) % duration;
    return elapsed / duration;
  }

  static String _hotp({
    required String secret,
    required int counter,
    required int length,
    required int hashAlgo,
  }) {
    final key = base32.decode(secret.toUpperCase().replaceAll(' ', ''));
    final msg = _counterBytes(counter);

    final Hmac hmac;
    switch (hashAlgo) {
      case 1:
        hmac = Hmac(sha256, key);
        break;
      case 2:
        hmac = Hmac(sha512, key);
        break;
      default:
        hmac = Hmac(sha1, key);
    }

    final digest = hmac.convert(msg).bytes;
    final offset = digest.last & 0x0f;
    final code = ((digest[offset] & 0x7f) << 24) |
        ((digest[offset + 1] & 0xff) << 16) |
        ((digest[offset + 2] & 0xff) << 8) |
        (digest[offset + 3] & 0xff);

    final otp = code % pow(10, length).toInt();
    return otp.toString().padLeft(length, '0');
  }

  static Uint8List _counterBytes(int counter) {
    final bytes = Uint8List(8);
    var c = counter;
    for (int i = 7; i >= 0; i--) {
      bytes[i] = c & 0xff;
      c >>= 8;
    }
    return bytes;
  }
}
