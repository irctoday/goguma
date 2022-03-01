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
		onOpen: (link) {
			launch(link.url);
		},
		style: textStyle,
		linkStyle: linkStyle,
	);
}
