import 'dart:typed_data';

import 'package:webcrypto/webcrypto.dart';

const _saltSize = 16;
const _ikmSize = 32;
const _contentEncryptionKeySize = 16;
const _nonceSize = 12;

const _paddingDelimiter = 0x02;

class WebPush {
	final EcdhPrivateKey _p256dhPrivateKey;
	final EcdhPublicKey _p256dhPublicKey;
	final Uint8List _authKey;

	WebPush._(this._p256dhPrivateKey, this._p256dhPublicKey, this._authKey);

	static Future<WebPush> generate() async {
		var authKey = Uint8List(16);
		fillRandomBytes(authKey);

		var p256dhKeyPair = await EcdhPrivateKey.generateKey(EllipticCurve.p256);
		return WebPush._(p256dhKeyPair.privateKey, p256dhKeyPair.publicKey, authKey);
	}

	static Future<WebPush> import(WebPushConfig raw) async {
		var p256dhPrivateKey = await EcdhPrivateKey.importPkcs8Key(raw.p256dhPrivateKey, EllipticCurve.p256);
		var p256dhPublicKey = await EcdhPublicKey.importRawKey(raw.p256dhPublicKey, EllipticCurve.p256);
		return WebPush._(p256dhPrivateKey, p256dhPublicKey, raw.authKey);
	}

	Future<Map<String, Uint8List>> exportPublicKeys() async {
		return {
			'p256dh': await _p256dhPublicKey.exportRawKey(),
			'auth': _authKey,
		};
	}

	Future<WebPushConfig> exportPrivateKeys() async {
		return WebPushConfig(
			p256dhPrivateKey: await _p256dhPrivateKey.exportPkcs8Key(),
			p256dhPublicKey: await _p256dhPublicKey.exportRawKey(),
			authKey: _authKey,
		);
	}

	Future<Uint8List> decrypt(List<int> buf) async {
		var offset = 0;

		var salt = buf.sublist(offset, offset + _saltSize);
		offset += salt.length;

		var recordSizeBytes = buf.sublist(offset, offset + 4);
		offset += recordSizeBytes.length;

		var serverPubKeySize = buf[offset];
		offset++;

		var serverPubKeyBytes = buf.sublist(offset, offset + serverPubKeySize);
		offset += serverPubKeyBytes.length;

		var body = buf.sublist(offset);

		var recordSize = ByteData.sublistView(Uint8List.fromList(recordSizeBytes)).getUint32(0, Endian.big);
		if (recordSize != buf.length) {
			throw FormatException('Encrypted payload size (${buf.length}) doesn\'t match record size field ($recordSize)');
		}

		var serverOneTimePubKey = await EcdhPublicKey.importRawKey(serverPubKeyBytes, EllipticCurve.p256);
		var sharedEcdhSecret = await _p256dhPrivateKey.deriveBits(32 * 8, serverOneTimePubKey);
		var clientPubKeyRaw = await _p256dhPublicKey.exportRawKey();

		var info = [
			...'WebPush: info'.codeUnits,
			0,
			...clientPubKeyRaw,
			...serverPubKeyBytes,
		];
		var hkdfSecretKey = await HkdfSecretKey.importRawKey(sharedEcdhSecret);
		var ikm = await hkdfSecretKey.deriveBits(_ikmSize * 8, Hash.sha256, _authKey, info);

		info = [...'Content-Encoding: aes128gcm'.codeUnits, 0];
		hkdfSecretKey = await HkdfSecretKey.importRawKey(ikm);
		var contentEncryptionKeyBytes = await hkdfSecretKey.deriveBits(_contentEncryptionKeySize * 8, Hash.sha256, salt, info);
		info = [...'Content-Encoding: nonce'.codeUnits, 0];
		var nonce = await hkdfSecretKey.deriveBits(_nonceSize * 8, Hash.sha256, salt, info);

		var aesSecretKey = await AesGcmSecretKey.importRawKey(contentEncryptionKeyBytes);
		var cleartext = await aesSecretKey.decryptBytes(body, nonce, tagLength: _contentEncryptionKeySize * 8);

		var paddingIndex = cleartext.lastIndexOf(_paddingDelimiter);
		if (paddingIndex < 0) {
			throw FormatException('Missing padding delimiter in cleartext');
		}
		cleartext = cleartext.sublist(0, paddingIndex);

		return cleartext;
	}
}

class WebPushConfig {
	final Uint8List p256dhPublicKey;
	final Uint8List p256dhPrivateKey;
	final Uint8List authKey;

	WebPushConfig({ required this.p256dhPublicKey, required this.p256dhPrivateKey, required this.authKey });

	Map<String, Uint8List> getPublicKeys() {
		return {
			'p256dh': p256dhPublicKey,
			'auth': authKey,
		};
	}
}
