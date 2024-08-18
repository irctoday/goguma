import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:linkify/linkify.dart' as lnk;
import 'package:linkify/linkify.dart' hide linkify;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'client.dart';
import 'models.dart';

List<LinkifyElement> extractLinks(String text, [NetworkModel? network]) {
	var linkifiers = [
		_UrlLinkifier(),
		_GeoLinkifier(),
		EmailLinkifier(),
		if (network != null) _IrcChannelLinkifier(network.uri.toString()),
	];
	return lnk.linkify(text, linkifiers: linkifiers, options: lnk.LinkifyOptions(
		humanize: false,
		defaultToHttps: true,
	));
}

TextSpan linkify(BuildContext context, String text, {
	required TextStyle linkStyle,
}) {
	NetworkModel? network;
	try {
		network = context.read<NetworkModel>();

		var client = context.read<Client>();
		if (!client.isupport.chanTypes.contains('#')) {
			network = null;
		}
	} on ProviderNotFoundException {
		// ignore
	}

	var children = extractLinks(text, network).map((elem) {
		if (elem is LinkableElement) {
			return TextSpan(
				text: elem.text,
				style: linkStyle,
				recognizer: TapGestureRecognizer()..onTap = () async {
					bool ok = await launchUrl(Uri.parse(elem.url));
					if (!ok) {
						throw Exception('Failed to launch URL: ${elem.url}');
					}
				},
			);
		} else {
			return TextSpan(text: elem.text);
		}
	}).toList();

	return TextSpan(children: children);
}

class _UrlLinkifier extends Linkifier {
	const _UrlLinkifier();

	@override
	List<LinkifyElement> parse(List<LinkifyElement> elements, LinkifyOptions options) {
		var out = <LinkifyElement>[];
		for (var element in elements) {
			if (element is TextElement) {
				_parseText(out, element.text);
			} else {
				out.add(element);
			}
		}
		return out;
	}

	void _parseText(List<LinkifyElement> out, String text) {
		while (text != '') {
			var i = -1;
			for (var proto in ['http', 'https', 'irc', 'ircs']) {
				i = text.indexOf(proto + '://');
				if (i >= 0) {
					break;
				}
			}
			if (i < 0) {
				out.add(TextElement(text));
				return;
			}

			if (i > 0) {
				out.add(TextElement(text.substring(0, i)));
				text = text.substring(i);
			}

			i = 0;
			for (; i < text.length; i++) {
				var ch = text[i];
				if (_isWhitespace(ch)) {
					break;
				}

				var nextCh = '';
				if (i + 1 < text.length) {
					nextCh = text[i + 1];
				}

				if (_isWhitespace(nextCh) && _isTrailing(ch)) {
					break;
				}
			}

			var url = text.substring(0, i);
			text = text.substring(i);

			if (Uri.tryParse(url) != null) {
				out.add(UrlElement(url));
			} else {
				out.add(TextElement(url));
			}
		}
	}

	// Returns true if the character should be ignored if it's the last one.
	bool _isTrailing(String ch) {
		switch (ch) {
		case '.':
		case '!':
		case '?':
		case ',':
		case ':':
		case ';':
		case ')':
		case '(':
		case '[':
		case ']':
		case '{':
		case '}':
		case '"':
			return true;
		default:
			return false;
		}
	}
}

class _IrcChannelLinkifier extends Linkifier {
	final String baseUri;

	const _IrcChannelLinkifier(this.baseUri);

	static final _charRegExp = RegExp(r'^[\p{Letter}0-9#.-]$', unicode: true);

	@override
	List<LinkifyElement> parse(List<LinkifyElement> elements, LinkifyOptions options) {
		var out = <LinkifyElement>[];
		for (var element in elements) {
			if (element is TextElement) {
				_parseText(out, element.text);
			} else {
				out.add(element);
			}
		}
		return out;
	}

	void _parseText(List<LinkifyElement> out, String text) {
		while (text != '') {
			var i = text.indexOf('#');
			var prevCh = '', nextCh = '';
			if (i > 0) {
				prevCh = text[i - 1];
			}
			if (i + 1 < text.length) {
				nextCh = text[i + 1];
			}
			if (i < 0 || !_isAllowedPrev(prevCh) || !_charRegExp.hasMatch(nextCh)) {
				out.add(TextElement(text));
				return;
			}

			if (i > 0) {
				out.add(TextElement(text.substring(0, i)));
				text = text.substring(i);
			}

			i = 0;
			for (; i < text.length; i++) {
				var ch = text[i];
				if (!_charRegExp.hasMatch(ch)) {
					break;
				}

				var nextCh = '';
				if (i + 1 < text.length) {
					nextCh = text[i + 1];
				}

				if (!_charRegExp.hasMatch(nextCh) && _isTrailing(ch)) {
					break;
				}
			}

			var channel = text.substring(0, i);
			out.add(UrlElement(baseUri + channel, channel));
			text = text.substring(i);
		}
	}

	bool _isAllowedPrev(String ch) {
		switch (ch) {
		case '(':
		case '[':
			return true;
		default:
			return _isWhitespace(ch);
		}
	}

	bool _isTrailing(String ch) {
		switch (ch) {
		case '.':
		case '-':
			return true;
		default:
			return false;
		}
	}
}

class _GeoLinkifier extends Linkifier {
	const _GeoLinkifier();

	@override
	List<LinkifyElement> parse(List<LinkifyElement> elements, LinkifyOptions options) {
		var out = <LinkifyElement>[];
		for (var element in elements) {
			if (element is TextElement) {
				_parseText(out, element.text);
			} else {
				out.add(element);
			}
		}
		return out;
	}

	void _parseText(List<LinkifyElement> out, String text) {
		while (text != '') {
			var i = text.indexOf('geo:');
			if (i < 0) {
				out.add(TextElement(text));
				return;
			}

			if (i > 0) {
				out.add(TextElement(text.substring(0, i)));
				text = text.substring(i);
			}

			i = 0;
			for (; i < text.length; i++) {
				var ch = text[i];
				if (_isWhitespace(ch)) {
					break;
				}

				var nextCh = '';
				if (i + 1 < text.length) {
					nextCh = text[i + 1];
				}

				if (nextCh != '' && _isWhitespace(nextCh)) {
					break;
				}
			}

			var url = text.substring(0, i);
			text = text.substring(i);

			var coords = _tryParseUri(url);
			if (coords != null) {
				// Sigh. It seems like there is a contest to be the worst geo
				// URI citizen between Android and iOS. Android supports geo
				// URIs but with a different flavor incompatible with the RFC.
				// iOS doesn't support geo URIs at all. Both need special
				// handling to display a pin.
				String? text;
				if (Platform.isAndroid) {
					text = url;
					url = 'geo:${coords[0]},${coords[1]}?q=${coords[0]},${coords[1]}(Position)';
				} else if (Platform.isIOS) {
					text = url;
					url = 'https://maps.apple.com/?ll=${coords[0]},${coords[1]}&q=Position';
				}
				out.add(UrlElement(url, text));
			} else {
				out.add(TextElement(url));
			}
		}
	}

	/// Parse a geo URI according to RFC 5870.
	List<double>? _tryParseUri(String url) {
		var path = url.replaceFirst('geo:', '');

		var i = path.indexOf(';'); // strip RFC parameters
		if (i < 0) {
			i = path.indexOf('?'); // strip Google Maps parameters
		}
		var coordsStr = path;
		if (i >= 0) {
			coordsStr = path.substring(0, i);
		}

		List<double> coords = [];
		for (var str in coordsStr.split(',')) {
			var coord = double.tryParse(str);
			if (coord == null) {
				return null;
			}
			coords.add(coord);
		}
		if (coords.length != 2 && coords.length != 3) {
			return null;
		}

		return coords;
	}
}

bool _isWhitespace(String ch) {
	return ch.trim() == '';
}
