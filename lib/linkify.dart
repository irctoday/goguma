import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:linkify/linkify.dart' as lnk;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'client.dart';
import 'models.dart';

List<LinkifyElement> extractLinks(String text, [NetworkModel? network]) {

	var linkifiers = [
		_UrlLinkifier(),
		EmailLinkifier(),
		if (network != null) _IrcChannelLinkifier(network.uri.toString()),
	];
	return lnk.linkify(text, linkifiers: linkifiers, options: lnk.LinkifyOptions(
		humanize: false,
		defaultToHttps: true,
	));
}

TextSpan linkify(BuildContext context, String text, {
	required TextStyle textStyle,
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

	var elements = extractLinks(text, network);
	return buildTextSpan(
		elements,
		onOpen: (link) async {
			bool ok = await launchUrl(Uri.parse(link.url), mode: LaunchMode.externalApplication);
			if (!ok) {
				throw Exception('Failed to launch URL: ${link.url}');
			}
		},
		style: textStyle,
		linkStyle: linkStyle,
	);
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

			out.add(UrlElement(text.substring(0, i)));
			text = text.substring(i);
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

bool _isWhitespace(String ch) {
	return ch.trim() == '';
}
