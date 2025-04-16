import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../cached_network_image.dart';
import '../link_preview.dart' as lib;
import '../page/gallery.dart';

typedef LinkPreviewBuilder = Widget Function(BuildContext context, Widget child);

class LinkPreview extends StatelessWidget {
	final String text;
	final LinkPreviewBuilder builder;

	const LinkPreview({
		required this.text,
		required this.builder,
		super.key,
	});

	@override
	Widget build(BuildContext context) {
		var linkPreviewer = context.read<lib.LinkPreviewer>();
		// Try to populate the initial data from cache, to avoid jitter in
		// the UI
		var cached = linkPreviewer.cachedPreviewText(text);
		Future<List<lib.LinkPreview>>? future;
		if (cached == null) {
			future = linkPreviewer.previewText(text);
		}
		return FutureBuilder<List<lib.LinkPreview>>(
			future: future,
			initialData: cached,
			builder: (context, snapshot) {
				if (snapshot.hasError) {
					Error.throwWithStackTrace(snapshot.error!, snapshot.stackTrace!);
				}
				var previews = snapshot.data;
				if (previews == null || previews.isEmpty) {
					return Container();
				}
				// TODO: support multiple previews
				var preview = previews.first;
				Widget child;
				if (preview.imageUrl != null) {
					child = _PhotoPreview(preview);
				} else {
					child = _AudioPreview(preview: preview);
				}
				return builder(context, child);
			},
		);
	}
}

class _PhotoPreview extends StatelessWidget {
	final lib.LinkPreview preview;
	final Object _heroTag;

	_PhotoPreview(this.preview) : _heroTag = Object();

	@override
	Widget build(BuildContext context) {
		return InkWell(
			onTap: () async {
				if (preview is lib.PhotoPreview) {
					await Navigator.pushNamed(context, GalleryPage.routeName, arguments: GalleryPageArguments(
						uri: preview.url,
						heroTag: _heroTag,
					));
				} else {
					bool ok = await launchUrl(preview.url);
					if (!ok) {
						throw Exception('Failed to launch URL: ${preview.url}');
					}
				}
			},
			child: Hero(tag: _heroTag, child: Image(
				image: CachedNetworkImage(preview.imageUrl.toString()),
				height: 250,
				fit: BoxFit.cover,
				filterQuality: FilterQuality.medium,
				loadingBuilder: (context, child, loadingProgress) {
					if (loadingProgress == null) {
						return child;
					}
					double? progress;
					if (loadingProgress.expectedTotalBytes != null) {
						progress = loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!;
					}
					return Container(
						width: 250,
						height: 250,
						alignment: Alignment.center,
						child: CircularProgressIndicator(
							value: progress,
						),
					);
				},
				errorBuilder: (context, error, stackTrace) {
					return Container(
						width: 250,
						height: 250,
						alignment: Alignment.center,
						child: Column(
							mainAxisAlignment: MainAxisAlignment.center,
							children: [
								Icon(Icons.error),
								Text(error.toString()),
							],
						),
					);
				},
			)),
		);
	}
}

class _AudioPreview extends StatefulWidget {
	final lib.LinkPreview preview;

	_AudioPreview({ required this.preview });

	@override
	State<StatefulWidget> createState() {
		return _AudioPreviewState();
	}
}

class _AudioPreviewState extends State<_AudioPreview> {
	late AudioPlayer _player;
	PlayerState? _playerState;
	Duration? _duration;
	Duration? _position;

	StreamSubscription<Duration>? _durationSubscription;
	StreamSubscription<Duration>? _positionSubscription;
	StreamSubscription<PlayerState>? _playerStateChangeSubscription;

	@override
	void initState() {
		super.initState();

		_player = AudioPlayer();
		_player.setAudioContext(AudioContext(
			android: AudioContextAndroid(
				audioFocus: AndroidAudioFocus.none,
				audioMode: AndroidAudioMode.normal,
				contentType: AndroidContentType.speech,
				usageType: AndroidUsageType.unknown,
			),
			iOS: AudioContextIOS(
				category: AVAudioSessionCategory.playback,
				options: { AVAudioSessionOptions.mixWithOthers },
			),
		));
		_player.setReleaseMode(ReleaseMode.stop);
		_player.setSourceUrl(widget.preview.audioUrl!.toString());

		_durationSubscription = _player.onDurationChanged.listen((duration) { setState(() => _duration = duration); });
		_positionSubscription = _player.onPositionChanged.listen((p) => setState(() => _position = p));
		_playerStateChangeSubscription = _player.onPlayerStateChanged.listen((state) { setState(() => _playerState = state);
		});
	}

	@override
	void dispose() {
		_durationSubscription?.cancel();
		_positionSubscription?.cancel();
		_playerStateChangeSubscription?.cancel();
		_player.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		double position = 0;
		if (_position != null && _duration != null && _position!.inMilliseconds > 0 && _position!.inMilliseconds < _duration!.inMilliseconds) {
			position = _position!.inMilliseconds / _duration!.inMilliseconds;
		}
		return Row(
			mainAxisSize: MainAxisSize.min,
			children: [
				IconButton(
					icon: Icon(_playerState == PlayerState.playing ? Icons.pause : Icons.play_arrow),
					onPressed: () async => _playerState == PlayerState.playing ? await _player.pause() : await _player.resume(),
				),
				Slider(
					onChanged: (value) {
						var duration = _duration;
						if (duration == null) {
							return;
						}
						var position = value * duration.inMilliseconds;
						_player.seek(Duration(milliseconds: position.round()));
					},
					value: position,
				),
				Text('${formatDuration(_position ?? Duration())} / ${formatDuration(_duration ?? Duration())}'),
			],
		);
	}

	String formatDuration(Duration duration) {
		var minutes = duration.inMinutes;
		var seconds = duration.inSeconds.remainder(60);
		var secondsText = seconds.toString().padLeft(2, '0');
		return '$minutes:$secondsText';
	}
}
