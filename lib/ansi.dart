import 'package:flutter/rendering.dart';

/// Strip ANSI formatting as defined in:
/// https://modern.ircdocs.horse/formatting.html
String stripAnsiFormatting(String s) {
	var out = '';
	for (var i = 0; i < s.length; i++) {
		var ch = s[i];
		switch (ch) {
		case '\x02': // bold
		case '\x1D': // italic
		case '\x1F': // underline
		case '\x1E': // strike-through
		case '\x11': // monospace
		case '\x16': // reverse color
		case '\x0F': // reset
			break; // skip
		case '\x03': // color
			if (i + 1 >= s.length || !_isDigit(s[i + 1])) {
				break;
			}
			i++;
			if (i + 1 < s.length && _isDigit(s[i + 1])) {
				i++;
			}
			if (i + 2 < s.length && s[i + 1] == ',' && _isDigit(s[i + 2])) {
				i += 2;
				if (i + 1 < s.length && _isDigit(s[i + 1])) {
					i++;
				}
			}
			break;
		case '\x04': // hex color
			i += 6;
			break;
		default:
			out += ch;
		}
	}
	return out;
}

var colorHexCodes = [
	0xffffffff, 0xff000000, 0xff00007f, 0xff009300, 0xffff0000, 0xff7f0000, 0xff9c009c, 0xfffc7f00, 0xffffff00, 0xff00fc00, 0xff009393, 0xff00ffff, 0xff0000fc, 0xffff00ff, 0xff7f7f7f, 0xff2d2d2d,
	0xff470000, 0xff472100, 0xff474700, 0xff324700, 0xff004700, 0xff00472c, 0xff004747, 0xff002747, 0xff000047, 0xff2e0047, 0xff470047, 0xff47002a,
	0xff740000, 0xff743a00, 0xff747400, 0xff517400, 0xff007400, 0xff007449, 0xff007474, 0xff004074, 0xff000074, 0xff4b0074, 0xff740074, 0xff740045,
	0xffb50000, 0xffb56300, 0xffb5b500, 0xff7db500, 0xff00b500, 0xff00b571, 0xff00b5b5, 0xff0063b5, 0xff0000b5, 0xff7500b5, 0xffb500b5, 0xffb5006b,
	0xffff0000, 0xffff8c00, 0xffffff00, 0xffb2ff00, 0xff00ff00, 0xff00ffa0, 0xff00ffff, 0xff008cff, 0xff0000ff, 0xffa500ff, 0xffff00ff, 0xffff0098,
	0xffff5959, 0xffffb459, 0xffffff71, 0xffcfff60, 0xff6fff6f, 0xff65ffc9, 0xff6dffff, 0xff59b4ff, 0xff5959ff, 0xffc459ff, 0xffff66ff, 0xffff59bc,
	0xffff9c9c, 0xffffd39c, 0xffffff9c, 0xffe2ff9c, 0xff9cff9c, 0xff9cffdb, 0xff9cffff, 0xff9cd3ff, 0xff9c9cff, 0xffdc9cff, 0xffff9cff, 0xffff94d3,
	0xff000000, 0xff131313, 0xff282828, 0xff363636, 0xff4d4d4d, 0xff656565, 0xff818181, 0xff9f9f9f, 0xffbcbcbc, 0xffe2e2e2, 0xffffffff,
];

/// Apply ANSI formatting as defined in:
/// https://modern.ircdocs.horse/formatting.html
List<TextSpan> applyAnsiFormatting(String s, TextStyle base) {
	var current = StringBuffer();
	List<TextSpan> spans = [];
	var bold = false;
	var italic = false;
	var underline = false;
	Color? fgColor;
	Color? bgColor;
	for (var i = 0; i <= s.length; i++) {
		var ch = i == s.length ? '\x0F' : s[i];
		switch (ch) {
		case '\x0F': // reset
		case '\x02': // bold
		case '\x1D': // italic
		case '\x1F': // underline
		case '\x03': // color
			List<TextDecoration> decorations = [base.decoration ?? TextDecoration.none];
			if (underline) {
				decorations.add(TextDecoration.underline);
			}
			spans.add(TextSpan(text: current.toString(), style: base.copyWith(
				fontWeight: bold ? FontWeight.bold : null,
				fontStyle: italic ? FontStyle.italic : null,
				decoration: TextDecoration.combine(decorations),
				color: fgColor,
				backgroundColor: bgColor,
			)));
			current.clear();
		}
		if (i == s.length) {
			break;
		}
		switch (ch) {
		case '\x0F': // reset
			bold = false;
			italic = false;
			underline = false;
			fgColor = null;
			bgColor = null;
			break;
		case '\x02': // bold
			bold = !bold;
			break;
		case '\x1D': // italic
			italic = !italic;
			break;
		case '\x1F': // underline
			underline = !underline;
			break;
		case '\x03': // color
			if (i + 1 >= s.length || !_isDigit(s[i + 1])) {
				fgColor = null;
				bgColor = null;
				break;
			}
			i++;
			var fg = s[i].codeUnits[0] - '0'.codeUnits[0];
			if (i + 1 < s.length && _isDigit(s[i + 1])) {
				i++;
				fg *= 10;
				fg += s[i].codeUnits[0] - '0'.codeUnits[0];
			}
			fgColor = fg == 99 ? null : Color(colorHexCodes[fg]);
			if (i + 2 < s.length && s[i + 1] == ',' && _isDigit(s[i + 2])) {
				i += 2;
				var bg = s[i].codeUnits[0] - '0'.codeUnits[0];
				if (i + 1 < s.length && _isDigit(s[i + 1])) {
					i++;
					bg *= 10;
					bg += s[i].codeUnits[0] - '0'.codeUnits[0];
				}
				bgColor = bg == 99 ? null : Color(colorHexCodes[bg]);
			}
			break;
		case '\x11': // monospace
		case '\x1E': // strike-through
		case '\x16': // reverse color
			// ignore, rarely used
			break;
		case '\x04': // hex color
			i += 6;
			// ignore, rarely used
			break;
		default:
			current.write(ch);
		}
	}
	return spans;
}

bool _isDigit(String ch) {
	return '0'.codeUnits.first <= ch.codeUnits.first && ch.codeUnits.first <= '9'.codeUnits.first;
}
