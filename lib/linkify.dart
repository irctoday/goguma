import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:linkify/linkify.dart' as lnk;
import 'package:url_launcher/url_launcher.dart';

TextSpan linkify(String text, { required TextStyle textStyle, required TextStyle linkStyle }) {
	var elements = lnk.linkify(text, options: lnk.LinkifyOptions(
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
