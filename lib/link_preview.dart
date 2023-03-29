import 'dart:async';
import 'dart:io';

import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as htmldom;
import 'package:linkify/linkify.dart' as lnk;

import 'database.dart';
import 'linkify.dart';
import 'logging.dart';

const maxPhotoSize = 10 * 1024 * 1024;
const maxHtmlSize = 1 * 1024 * 1024;
const peekHtmlSize = 4096;
const minImageDimensions = 250;

class LinkPreviewer {
	final HttpClient _client = HttpClient();
	final DB _db;
	final Map<String, Future<PhotoPreview?>> _pending = {};
	final Map<String, PhotoPreview?> _cached = {};

	LinkPreviewer(DB db) : _db = db;

	void dispose() {
		_client.close();
	}

	bool _validateUrl(Uri url) {
		return url.scheme == 'https' && !url.host.isEmpty;
	}

	bool _validateUrlStr(String str) {
		var url = Uri.tryParse(str);
		return url != null && _validateUrl(url);
	}

	String? _findOpenGraph(htmldom.Document doc, String name) {
		var elem = doc.querySelector('head > meta[property="$name"]');
		return elem?.attributes['content'];
	}

	int? _findOpenGraphInt(htmldom.Document doc, String name) {
		var value = _findOpenGraph(doc, name);
		if (value == null) {
			return null;
		}
		return int.tryParse(value);
	}

	Future<LinkPreviewEntry> _fetchHtmlPreview(Uri url, LinkPreviewEntry entry, bool reqRange) async {
		var req = await _client.getUrl(url);
		if (reqRange) {
			req.headers.set('Range', 'bytes=0-${peekHtmlSize-1}');
		}
		var resp = await req.close();
		if (resp.statusCode ~/ 100 != 2) {
			throw Exception('HTTP error fetching $url: ${resp.statusCode}');
		}
		var buf = await resp.take(peekHtmlSize).reduce((a, b) => [...a, ...b]);
		// TODO: find a way to discard the rest of the response?
		var doc = html.parse(buf);

		// OpenGraph, see https://ogp.me/
		var ogImage = _findOpenGraph(doc, 'og:image');
		var ogImageWidth = _findOpenGraphInt(doc, 'og:image:width');
		var ogImageHeight = _findOpenGraphInt(doc, 'og:image:height');
		var imageDimValid = (ogImageWidth ?? minImageDimensions) >= minImageDimensions && (ogImageHeight ?? minImageDimensions) >= minImageDimensions;
		if (ogImage != null && _validateUrlStr(ogImage) && imageDimValid) {
			entry.imageUrl = ogImage;
		}

		// TODO: add support for oEmbed, see https://oembed.com/
		return entry;
	}

	Future<LinkPreviewEntry?> _fetchPreview(Uri url) async {
		if (!_validateUrl(url)) {
			return null;
		}

		var req = await _client.headUrl(url);
		var resp = await req.close();
		if (resp.statusCode ~/ 100 != 2) {
			throw Exception('HTTP error fetching $url: ${resp.statusCode}');
		}

		var entry = LinkPreviewEntry(
			url: url.toString(),
			statusCode: resp.statusCode,
			mimeType: resp.headers.contentType?.mimeType,
			contentLength: resp.headers.contentLength > 0 ? resp.headers.contentLength : null,
		);

		if (resp.headers.contentType?.mimeType == 'text/html') {
			var acceptsByteRanges = resp.headers.value('Accept-Ranges') == 'bytes';
			var useByteRanges = resp.headers.contentLength > peekHtmlSize && acceptsByteRanges;
			if (useByteRanges || resp.headers.contentLength < maxHtmlSize) {
				return await _fetchHtmlPreview(url, entry, useByteRanges);
			}
		}

		return entry;
	}

	Future<PhotoPreview?> _previewUrl(Uri url) async {
		var entry = await _db.fetchLinkPreview(url.toString());
		if (entry != null) {
			return PhotoPreview._fromEntry(entry);
		}

		try {
			entry = await _fetchPreview(url);
		} on Exception catch (err) {
			log.print('Failed to fetch link preview for <$url>', error: err);
		}
		if (entry == null) {
			return null;
		}

		await _db.storeLinkPreview(entry);
		return PhotoPreview._fromEntry(entry);
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
			unawaited(_pending.remove(k));
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

	static PhotoPreview? _fromEntry(LinkPreviewEntry entry) {
		var mimeType = entry.mimeType;
		if (mimeType == null) {
			return null;
		}

		if (mimeType.startsWith('image/')) {
			if (entry.contentLength != null && entry.contentLength! > maxPhotoSize) {
				return null;
			}
			return PhotoPreview(Uri.parse(entry.url));
		} else if (entry.imageUrl != null) {
			return PhotoPreview(Uri.parse(entry.imageUrl!));
		} else {
			return null;
		}
	}
}
