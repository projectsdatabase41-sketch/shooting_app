import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// Проверяем саму криптосхему медиа-хранилища без сети и без базы:
/// две стороны выводят один и тот же ключ из X25519 + HKDF, файл
/// шифруется и расшифровывается, «чужой» ключ не подходит.
void main() {
  final x25519 = X25519();
  final aes = AesGcm.with256bits();
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  Future<List<int>> shared(SimpleKeyPair mine, SimplePublicKey peer) async {
    final secret = await x25519.sharedSecretKey(keyPair: mine, remotePublicKey: peer);
    final key = await hkdf.deriveKey(secretKey: secret, nonce: const [], info: utf8.encode('nexus-media-v1'));
    return key.extractBytes();
  }

  test('X25519 + HKDF: общий ключ совпадает у обеих сторон', () async {
    final alice = await x25519.newKeyPair();
    final bob = await x25519.newKeyPair();
    final a = await shared(alice, await bob.extractPublicKey());
    final b = await shared(bob, await alice.extractPublicKey());
    expect(a, equals(b));
    expect(a.length, 32);
  });

  test('AES-256-GCM: файл шифруется и расшифровывается', () async {
    final alice = await x25519.newKeyPair();
    final bob = await x25519.newKeyPair();
    final keyBytes = await shared(alice, await bob.extractPublicKey());
    final key = SecretKey(keyBytes);
    final clear = Uint8List.fromList(List.generate(5000, (i) => i % 256));

    final box = await aes.encrypt(clear, secretKey: key);
    final wire = Uint8List.fromList(box.concatenation());
    expect(wire.length, greaterThan(clear.length)); // + nonce + mac
    expect(base64Encode(wire), isNot(base64Encode(clear)));

    final back = await aes.decrypt(
      SecretBox.fromConcatenation(wire, nonceLength: 12, macLength: 16),
      secretKey: key,
    );
    expect(back, equals(clear));
  });

  test('чужой ключ: расшифровка не удаётся', () async {
    final alice = await x25519.newKeyPair();
    final bob = await x25519.newKeyPair();
    final eve = await x25519.newKeyPair();
    final key = SecretKey(await shared(alice, await bob.extractPublicKey()));
    final wrong = SecretKey(await shared(alice, await eve.extractPublicKey()));
    final box = await aes.encrypt(List<int>.filled(64, 7), secretKey: key);
    expect(
      () => aes.decrypt(
        SecretBox.fromConcatenation(box.concatenation(), nonceLength: 12, macLength: 16),
        secretKey: wrong,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });
}
