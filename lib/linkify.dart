import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:linkify/linkify.dart' as lnk;
import 'package:url_launcher/url_launcher.dart';

TextSpan linkify(String text, { required TextStyle textStyle, required TextStyle linkStyle }) {
	var linkifiers = const [
		_UrlLinkifier(),
		EmailLinkifier(),
	];
	var elements = lnk.linkify(text, linkifiers: linkifiers, options: lnk.LinkifyOptions(
		humanize: false,
		defaultToHttps: true,
	));
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
				if (ch.trim() == '') {
					break; // whitespace
				}

				var nextCh = '';
				if (i + 1 < text.length) {
					nextCh = text[i + 1];
				}

				if (nextCh.trim() == '' && _isTrailing(ch)) {
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
