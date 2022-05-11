import 'dart:io';

import 'package:linkify/linkify.dart' as lnk;

import 'linkify.dart';

const maxPhotoSize = 10 * 1024 * 1024;

class LinkPreviewer {
	final HttpClient _client = HttpClient();

	void dispose() {
		_client.close();
	}

	Future<PhotoPreview?> previewUrl(Uri url) async {
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

		return PhotoPreview(url);
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
}

class PhotoPreview {
	final Uri url;

	PhotoPreview(this.url);
}
