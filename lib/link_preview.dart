import 'dart:io';

import 'package:linkify/linkify.dart' as lnk;

import 'database.dart';
import 'linkify.dart';

const maxPhotoSize = 10 * 1024 * 1024;

class LinkPreviewer {
	final HttpClient _client = HttpClient();
	final DB _db;
	final Map<String, Future<PhotoPreview?>> _pending = {};
	final Map<String, PhotoPreview?> _cached = {};

	LinkPreviewer(DB db) : _db = db;

	void dispose() {
		_client.close();
	}

	Future<LinkPreviewEntry?> _fetchPreview(Uri url) async {
		if (url.scheme != 'https') {
			return null;
		}

		var req = await _client.headUrl(url);
		var resp = await req.close();
		if (resp.statusCode ~/ 100 != 2) {
			throw Exception('HTTP error fetching $url: ${resp.statusCode}');
		}

		if (resp.headers.contentType?.primaryType != 'image') {
			return null;
		}
		if (resp.headers.contentLength > maxPhotoSize) {
			return null;
		}

		return LinkPreviewEntry(
			url: url.toString(),
			statusCode: resp.statusCode,
			mimeType: resp.headers.contentType?.mimeType,
			contentLength: resp.headers.contentLength > 0 ? resp.headers.contentLength : null,
		);
	}

	Future<PhotoPreview?> _previewUrl(Uri url) async {
		var entry = await _db.fetchLinkPreview(url.toString());
		if (entry != null) {
			return PhotoPreview(url);
		}

		try {
			entry = await _fetchPreview(url);
		} on Exception catch (err) {
			print('Failed to fetch link preview for <$url>: $err');
		}
		if (entry == null) {
			return null;
		}

		await _db.storeLinkPreview(entry);
		return PhotoPreview(url);
	}

	Future<PhotoPreview?> previewUrl(Uri url) async {
		var k = url.toString();

		if (_cached.containsKey(k)) {
			return _cached[k];
		}

		var pending = _pending[k];
		if (pending != null) {
			return await pending;
		}

		var future = _previewUrl(url);
		_pending[k] = future;
		PhotoPreview? preview;
		try {
			preview = await future;
		} finally {
			_pending.remove(k);
		}

		_cached[k] = preview;
		return preview;
	}

	Future<List<PhotoPreview>> previewText(String text) async {
		var links = extractLinks(text);

		List<PhotoPreview> previews = [];
		await Future.wait(links.map((link) async {
			if (link is lnk.UrlElement) {
				var preview = await previewUrl(Uri.parse(link.url));
				if (preview != null) {
					previews.add(preview);
				}
			}
		}));

		return previews;
	}

	List<PhotoPreview>? cachedPreviewText(String text) {
		var links = extractLinks(text);

		List<PhotoPreview> previews = [];
		for (var link in links) {
			if (!(link is lnk.UrlElement)) {
				continue;
			}
			if (!_cached.containsKey(link.url)) {
				return null;
			}
			var preview = _cached[link.url];
			if (preview != null) {
				previews.add(preview);
			}
		}

		return previews;
	}
}

class PhotoPreview {
	final Uri url;

	PhotoPreview(this.url);
}
