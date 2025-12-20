import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../emoji.dart';
import '../irc.dart';
import '../linkify.dart';
import '../models.dart';
import '../prefs.dart';
import '../widget/link_preview.dart';
import '../widget/message_sheet.dart';
import '../widget/reactions_sheet.dart';
import '../widget/swipe_action.dart';

class RegularMessageItem extends StatelessWidget {
	final MessageModel msg;
	final MessageModel? prevMsg, nextMsg;
	final String? unreadMarkerTime;
	final VoidCallback? onReply;
	final void Function(int)? onMsgRefTap;

	const RegularMessageItem({
		super.key,
		required this.msg,
		this.prevMsg,
		this.nextMsg,
		this.unreadMarkerTime,
		this.onReply,
		this.onMsgRefTap,
	});

	@override
	Widget build(BuildContext context) {
		var client = context.read<Client>();
		var prefs = context.read<Prefs>();
		var network = context.read<NetworkModel>();

		var ircMsg = msg.msg;
		var entry = msg.entry;
		var sender = ircMsg.source!.name;
		var localDateTime = entry.dateTime.toLocal();
		var ctcp = CtcpMessage.parse(ircMsg);
		var hasChannelContext = ircMsg.tags['+draft/channel-context'] != null;
		var isFromMe = client.isMyNick(sender);
		assert(ircMsg.cmd == 'PRIVMSG' || ircMsg.cmd == 'NOTICE');

		var body = ircMsg.params[1];
		const maxEmotesForBigFont = 5;
		// use .take to avoid processing the entire string
		var bigEmotes = !entry.redacted && body.isNotEmpty &&
			body.characters.take(maxEmotesForBigFont + 1).length <= maxEmotesForBigFont &&
			body.characters.every(isEmoji);

		var target = ircMsg.params[0];
		var i = parseTargetPrefix(target, client.isupport.statusMsg);
		var statusMsgPrefix = target.substring(0, i);

		var prevIrcMsg = prevMsg?.msg;
		var prevCtcp = prevIrcMsg != null ? CtcpMessage.parse(prevIrcMsg) : null;
		var prevEntry = prevMsg?.entry;
		var prevMsgSameSender = prevIrcMsg != null && ircMsg.source!.name == prevIrcMsg.source!.name;
		var prevMsgIsAction = prevCtcp != null && prevCtcp.cmd == 'ACTION';

		var nextMsgSameSender = nextMsg != null && ircMsg.source!.name == nextMsg!.msg.source!.name;

		var isAction = ctcp != null && ctcp.cmd == 'ACTION';
		var showUnreadMarker = prevEntry != null && unreadMarkerTime != null && unreadMarkerTime!.compareTo(entry.time) < 0 && unreadMarkerTime!.compareTo(prevEntry.time) >= 0;
		var showDateMarker = prevEntry == null || !_isSameDate(localDateTime, prevEntry.dateTime.toLocal());
		var isFirstInGroup = showUnreadMarker || !prevMsgSameSender || prevMsgIsAction != isAction || hasChannelContext || statusMsgPrefix != '';
		var showTime = !nextMsgSameSender || nextMsg!.entry.dateTime.difference(entry.dateTime) > Duration(minutes: 2);

		var colorScheme = Theme.of(context).colorScheme;
		var unreadMarkerColor = colorScheme.secondary;
		var eventColor = DefaultTextStyle.of(context).style.color!.withValues(alpha: 0.5);

		var boxColor = colorScheme.surfaceContainer;
		var boxAlignment = Alignment.centerLeft;
		var textColor =  colorScheme.onSurface;
		var senderNickColor = _getNickColor(sender, colorScheme.brightness);

		if (isFromMe) {
			boxColor = colorScheme.primaryContainer;
			// Actions are displayed as if they were told by an external
			// narrator. To preserve this effect, always show actions on the
			// left side.
			if (!isAction) boxAlignment = Alignment.centerRight;
			textColor = colorScheme.onPrimaryContainer;
			senderNickColor = textColor;
		}

		const margin = 16.0;
		var marginBottom = margin;
		if (nextMsg != null) {
			marginBottom = 0.0;
		}
		var marginTop = margin;
		if (!isFirstInGroup) {
			marginTop = margin / 4;
		}

		var senderTextSpan = TextSpan(
			text: sender,
			style: TextStyle(
				fontWeight: FontWeight.bold,
				color: isAction ? textColor : senderNickColor,
			),
		);
		if (hasChannelContext) {
			senderTextSpan = TextSpan(children: [
				senderTextSpan,
				TextSpan(text: ' (only visible to you)', style: TextStyle(color: textColor.withValues(alpha: 0.5))),
			]);
		} else if (statusMsgPrefix != '') {
			senderTextSpan = TextSpan(children: [
				senderTextSpan,
				TextSpan(text: ' (only visible to $statusMsgPrefix)', style: TextStyle(color: textColor.withValues(alpha: 0.5))),
			]);
		}

		var linkStyle = TextStyle(
			decoration: TextDecoration.underline,
			decorationColor: textColor,
		);

		List<InlineSpan> content;
		Widget? linkPreview;
		if (isAction) {
			content = [
				WidgetSpan(
					child: Container(
						width: 8.0,
						height: 8.0,
						margin: EdgeInsets.all(3.0),
						decoration: BoxDecoration(
							shape: BoxShape.circle,
							color: senderNickColor,
						),
					),
				),
				senderTextSpan,
				TextSpan(text: ' '),
				_formatText(
					context,
					ctcp.param ?? '',
					nick: network.nickname,
					linkStyle: linkStyle,
					backgroundColor: colorScheme.surface,
					isFromMe: isFromMe,
				),
			];
		} else if (bigEmotes) {
			content = [
				if (isFirstInGroup && !isFromMe) senderTextSpan,
				if (isFirstInGroup && !isFromMe) TextSpan(text: '\n'),
				TextSpan(text: ircMsg.params[1], style: TextStyle(fontSize: 42)),
			];
		} else {
			WidgetSpan? replyChip;
			if (msg.replyTo != null && msg.replyTo!.msg.source != null) {
				var replyNickname = msg.replyTo!.msg.source!.name;

				var replyPrefix = '$replyNickname: ';
				if (body.startsWith(replyPrefix)) {
					body = body.replaceFirst(replyPrefix, '');
				}

				replyChip = WidgetSpan(
					alignment: PlaceholderAlignment.middle,
					child: ActionChip(
						avatar: Icon(Icons.reply, size: 16, color: textColor),
						label: Text(replyNickname),
						labelPadding: EdgeInsets.only(right: 4),
						backgroundColor: Color.alphaBlend(textColor.withValues(alpha: 0.15), boxColor),
						labelStyle: TextStyle(color: textColor),
						visualDensity: VisualDensity(vertical: -4),
						onPressed: () {
							if (onMsgRefTap != null) {
								onMsgRefTap!(msg.replyTo!.id!);
							}
						},
					),
				);
			}

			TextSpan bodyTextSpan;
			if (entry.redacted) {
				bodyTextSpan = TextSpan(
					text: 'This message has been deleted.',
					style: TextStyle(fontStyle: FontStyle.italic),
				);
			} else {
				bodyTextSpan = _formatText(
					context,
					body,
					nick: network.nickname,
					linkStyle: linkStyle,
					backgroundColor: boxColor,
					isFromMe: isFromMe,
				);
			}

			content = [
				if (isFirstInGroup && !isFromMe) senderTextSpan,
				if (isFirstInGroup && !isFromMe) TextSpan(text: '\n'),
				if (replyChip != null) replyChip,
				if (replyChip != null) WidgetSpan(child: SizedBox(width: 5, height: 5)),
				bodyTextSpan,
			];

			if (prefs.linkPreview) {
				linkPreview = LinkPreview(
					text: body,
					builder: (context, child) {
						return Align(alignment: boxAlignment, child: Container(
							margin: EdgeInsets.only(top: 5),
							child: ClipRRect(
								borderRadius: BorderRadius.circular(10),
								child: child,
							),
						));
					},
				);
			}
		}

		Widget inner = Text.rich(TextSpan(children: content));

		if (showTime) {
			var hh = localDateTime.hour.toString().padLeft(2, '0');
			var mm = localDateTime.minute.toString().padLeft(2, '0');
			var time = '   $hh:$mm';
			var timeScreenReader = 'Sent at $hh $mm';
			var timeStyle = DefaultTextStyle.of(context).style.apply(
				color: textColor.withValues(alpha: 0.5),
				fontSizeFactor: 0.8,
			);

			// Add a fully transparent text span with the time, so that the real
			// time text doesn't collide with the message text.
			content.add(WidgetSpan(
				child: Text(
					time,
					style: timeStyle.apply(color: Color(0x00000000)),
					semanticsLabel: '',  // Make screen reader quiet
				),
			));

			inner = Stack(children: [
				inner,
				Positioned(
					bottom: 0,
					right: 0,
					child: Text(
						time,
						style: timeStyle,
						semanticsLabel: timeScreenReader,
					),
				),
			]);
		}

		inner = DefaultTextStyle.merge(style: TextStyle(color: textColor), child: inner);

		Widget decoratedMessage;
		if (isAction || bigEmotes) {
			decoratedMessage = inner;
		} else {
			decoratedMessage = ConstrainedBox(
				constraints: BoxConstraints(
					// Message bubbles are 80% of the screen width at most
					maxWidth: MediaQuery.of(context).size.width * 0.8,
				),
				child: Stack(children: [
					Container(
						decoration: BoxDecoration(
							borderRadius: BorderRadius.circular(10),
							color: boxColor,
						),
						margin: msg.reactions.isEmpty ? null : EdgeInsets.only(bottom: 25),
						padding: EdgeInsets.all(10),
						child: inner,
					),
					if (!msg.reactions.isEmpty) Positioned(
						bottom: 4,
						right: 10,
						child: _ReactionsRow(msg),
					),
				]),
			);
		}

		decoratedMessage = SwipeAction(
			background: Align(
				alignment: Alignment.centerLeft,
				child: Opacity(
					opacity: 0.6,
					child: Icon(Icons.reply),
				),
			),
			onSwipe: onReply,
			child: decoratedMessage,
		);

		decoratedMessage = Align(
			alignment: boxAlignment,
			child: decoratedMessage,
		);

		decoratedMessage = GestureDetector(
			onLongPress: () {
				var buffer = context.read<BufferModel>();
				MessageSheet.open(context, buffer, msg, onReply);
			},
			child: decoratedMessage,
		);

		return Column(children: [
			if (showUnreadMarker) Container(
				margin: EdgeInsets.only(top: margin),
				child: Row(children: [
					Expanded(child: Divider(color: unreadMarkerColor)),
					SizedBox(width: 10),
					Text('Unread messages', style: TextStyle(color: unreadMarkerColor)),
					SizedBox(width: 10),
					Expanded(child: Divider(color: unreadMarkerColor)),
				]),
			),
			if (showDateMarker) Container(
				margin: EdgeInsets.symmetric(vertical: 20),
				child: Center(child: Text(_formatDate(localDateTime), style: TextStyle(color: eventColor))),
			),
			Container(
				margin: EdgeInsets.only(left: margin, right: margin, top: marginTop, bottom: marginBottom),
				child: Column(children: [
					decoratedMessage,
					if (linkPreview != null) linkPreview,
				]),
			),
		]);
	}
}

class _ReactionsRow extends StatelessWidget {
	final MessageModel message;

	late final List<MapEntry<String, int>> _reactions;
	late final int _overflow;

	_ReactionsRow(this.message) {
		var map = message.reactionMap;
		var entries = map.entries
			.map((entry) => MapEntry(entry.key, entry.value.length))
			.toList();
		if (entries.length > 3) {
			entries.sort((a, b) => a.value.compareTo(b.value));
			entries = entries.take(2).toList();
		}
		_reactions = entries;
		_overflow = map.length - entries.length;
	}

	@override
	Widget build(BuildContext context) {
		MapEntry<String, int>? overflowEntry;
		if (_overflow > 0) {
			overflowEntry = MapEntry('+$_overflow', 0);
		}

		var reactions = _reactions.followedBy([
			if (overflowEntry != null) overflowEntry,
		]).map((reactionEntry) {
			return _ReactionChip(
				text: reactionEntry.key,
				count: reactionEntry.value,
				message: message,
			);
		}).toList();

		return Row(spacing: 2, children: reactions);
	}
}

class _ReactionChip extends StatelessWidget {
	final String text;
	final int count;
	final MessageModel message;
	final Color? borderColor;
	final Color? backgroundColor;

	const _ReactionChip({
		required this.text,
		required this.count,
		required this.message,
		this.borderColor,
		this.backgroundColor,
	});

	@override
	Widget build(BuildContext context) {
		var content = text;
		if (count > 1) {
			content = '$text $count';
		}

		var fg = Theme.of(context).colorScheme.secondaryContainer;
		var bg = Theme.of(context).colorScheme.surface;
		return GestureDetector(
			onTap: () {
				var buffer = context.read<BufferModel>();
				ReactionsSheet.open(context, buffer, message);
			},
			child: Container(
				padding: EdgeInsets.symmetric(vertical: 2, horizontal: 7),
				alignment: Alignment.center,
				decoration: BoxDecoration(
					border: Border.all(
						width: 1,
						color: borderColor ?? bg,
					),
					borderRadius: BorderRadius.circular(100),
					color: backgroundColor ?? fg,
				),
				child: Text(content),
			),
		);
	}
}

class CompactMessageItem extends StatelessWidget {
	final MessageModel msg;
	final MessageModel? prevMsg;
	final String? unreadMarkerTime;
	final VoidCallback? onReply;
	final bool last;

	const CompactMessageItem({
		super.key,
		required this.msg,
		this.prevMsg,
		this.unreadMarkerTime,
		this.onReply,
		this.last = false,
	});

	@override
	Widget build(BuildContext context) {
		var prefs = context.read<Prefs>();
		var ircMsg = msg.msg;
		var entry = msg.entry;
		var sender = ircMsg.source!.name;
		var localDateTime = entry.dateTime.toLocal();
		var ctcp = CtcpMessage.parse(ircMsg);
		assert(ircMsg.cmd == 'PRIVMSG' || ircMsg.cmd == 'NOTICE');

		var prevIrcMsg = prevMsg?.msg;
		var prevEntry = prevMsg?.entry;
		var prevMsgSameSender = prevIrcMsg != null && ircMsg.source!.name == prevIrcMsg.source!.name;
		var showUnreadMarker = prevEntry != null && unreadMarkerTime != null && unreadMarkerTime!.compareTo(entry.time) < 0 && unreadMarkerTime!.compareTo(prevEntry.time) >= 0;
		var showDateMarker = prevEntry == null || !_isSameDate(localDateTime, prevEntry.dateTime.toLocal());

		var unreadMarkerColor = Theme.of(context).colorScheme.secondary;
		var textStyle = TextStyle(color: Theme.of(context).textTheme.bodyLarge!.color);

		String? text;
		List<TextSpan> textSpans;
		if (ctcp != null) {
			textStyle = textStyle.apply(fontStyle: FontStyle.italic);

			if (ctcp.cmd == 'ACTION') {
				text = ctcp.param;
				textSpans = applyAnsiFormatting(text ?? '', textStyle);
			} else {
				textSpans = [TextSpan(text: 'has sent a CTCP "${ctcp.cmd}" command', style: textStyle)];
			}
		} else if (entry.redacted) {
			textSpans = [TextSpan(
				text: 'This message has been deleted.',
				style: TextStyle(fontStyle: FontStyle.italic),
			)];
		} else {
			text = ircMsg.params[1];
			textSpans = applyAnsiFormatting(text, textStyle);
		}

		textSpans = textSpans.map((span) {
			var linkSpan = linkify(context, span.text!, linkStyle: TextStyle(decoration: TextDecoration.underline));
			return TextSpan(style: span.style, children: [linkSpan]);
		}).toList();

		List<Widget> stack = [];
		List<InlineSpan> content = [];

		if (!prevMsgSameSender) {
			var senderStyle = TextStyle(
				color: _getNickColor(sender, Theme.of(context).colorScheme.brightness),
				fontWeight: FontWeight.bold,
			);
			stack.add(Positioned(
				top: 0,
				left: 0,
				child: Text(sender, style: senderStyle),
			));
			content.add(WidgetSpan(
				alignment: PlaceholderAlignment.top,
				child: SelectionContainer.disabled(
					child: Text(
						sender,
						style: senderStyle.apply(color: Color(0x00000000)),
						semanticsLabel: '',  // Make screen reader quiet
						textScaler: TextScaler.noScaling,
					),
				),
			));
		}

		content.addAll(textSpans);

		if (!prevMsgSameSender || prevEntry == null || entry.dateTime.difference(prevEntry.dateTime) > Duration(minutes: 2)) {
			var hh = localDateTime.hour.toString().padLeft(2, '0');
			var mm = localDateTime.minute.toString().padLeft(2, '0');
			var timeText = '\u00A0[$hh:$mm]';
			var timeStyle = TextStyle(color: Theme.of(context).textTheme.bodySmall!.color);
			stack.add(Positioned(
				bottom: 0,
				right: 0,
				child: Text(timeText, style: timeStyle),
			));
			content.add(WidgetSpan(
				alignment: PlaceholderAlignment.top,
				child: SelectionContainer.disabled(
					child: Text(
						timeText,
						style: timeStyle.apply(color: Color(0x00000000)),
						semanticsLabel: '',  // Make screen reader quiet
						textScaler: TextScaler.noScaling,
					),
				),
			));
		}

		var fg = Theme.of(context).colorScheme.secondaryContainer;
		var reactions = msg.reactionMap.entries.map((reactionEntry) {
			return _ReactionChip(
				text: reactionEntry.key,
				count: reactionEntry.value.length,
				message: msg,
				borderColor: fg,
				backgroundColor: fg.withAlpha(30),
			);
		}).toList();

		stack.add(Container(
			margin: EdgeInsets.only(left: 4),
			child: Stack(children: [
				Container(
					margin: reactions.isEmpty ? null : EdgeInsets.only(bottom: 30),
					child: GestureDetector(
						onLongPress: () {
							var buffer = context.read<BufferModel>();
							MessageSheet.open(context, buffer, msg, onReply);
						},
						child: Text.rich(
							TextSpan(
								children: content,
							),
						),
					),
				),
				if (!reactions.isEmpty) Positioned(bottom: 4, child: Row(spacing: 2, children: reactions)),
			]),
		));

		Widget? linkPreview;
		if (prefs.linkPreview && text != null) {
			var body = stripAnsiFormatting(text);
			linkPreview = LinkPreview(
				text: body,
				builder: (context, child) {
					return Align(alignment: Alignment.center, child: Container(
						margin: EdgeInsets.symmetric(vertical: 5),
						child: ClipRRect(
							borderRadius: BorderRadius.circular(10),
							child: child,
						),
					));
				},
			);
		}

		return Column(children: [
			if (showUnreadMarker) Row(children: [
				Expanded(child: Divider(color: unreadMarkerColor)),
				SizedBox(width: 10),
				Text('Unread messages', style: TextStyle(color: unreadMarkerColor)),
				SizedBox(width: 10),
				Expanded(child: Divider(color: unreadMarkerColor)),
			]),
			if (showDateMarker)
				Container(
					margin: EdgeInsets.only(top: 2.5),
					alignment: Alignment.center,
					child: Text(_formatDate(localDateTime), style: textStyle),
				),
			Container(
				margin: EdgeInsets.only(top: prevMsgSameSender ? 0 : 2.5, bottom: last ? 10 : 0, left: 4, right: 5),
				child: DefaultTextStyle.merge(
					style: TextStyle(height: 1.15),
					child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
						Stack(children: stack),
						if (linkPreview != null) linkPreview,
					]),
				),
			),
		]);
	}
}

bool _isSameDate(DateTime a, DateTime b) {
	return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _formatDate(DateTime dt) {
	var yyyy = dt.year.toString().padLeft(4, '0');
	var mm = dt.month.toString().padLeft(2, '0');
	var dd = dt.day.toString().padLeft(2, '0');
	return '$yyyy-$mm-$dd';
}

TextSpan _formatText(BuildContext context, String text, {
	required String nick,
	required TextStyle linkStyle,
	required Color backgroundColor,
	required bool isFromMe,
}) {
	text = stripAnsiFormatting(text);

	if (isFromMe) return linkify(context, text, linkStyle: linkStyle);

	var highlightIndexes = findTextHighlights(text, nick);
	List<InlineSpan> children = [];
	for (var i in highlightIndexes) {
		children.add(linkify(context, text.substring(0, i), linkStyle: linkStyle));
		children.add(WidgetSpan(
			alignment: PlaceholderAlignment.middle,
			child: Builder(builder: (context) => Container(
				padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1),
				decoration: BoxDecoration(
					color: DefaultTextStyle.of(context).style.color!,
					borderRadius: BorderRadius.circular(5),
				),
				child: Text(nick, style: TextStyle(color: backgroundColor)),
			)),
		));
		text = text.substring(i + nick.length);
	}
	children.add(linkify(context, text, linkStyle: linkStyle));

	return TextSpan(children: children);
}

// _getNickColor returns a color for the given nickname. The same nickname will always get the same color. The color is chosen from the primary colors of the current theme. The brightness parameter is used to choose a lighter or darker shade of the color.
Color _getNickColor(String nickname, Brightness brightness) {
	var colorSwatch = Colors.primaries[nickname.hashCode % Colors.primaries.length];
	return brightness == Brightness.dark ? colorSwatch.shade400 : colorSwatch.shade800;
}

