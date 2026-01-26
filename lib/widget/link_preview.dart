import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

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
				} else if (preview.videoUrl != null && !Platform.isLinux && !Platform.isWindows) {
					child = _VideoPreview(preview);
				} else {
					return Container();
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

class _VideoPreview extends StatefulWidget {
	final lib.LinkPreview preview;

	const _VideoPreview(this.preview);

	@override
	State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
	late VideoPlayerController _controller;

	@override
	void initState() {
		super.initState();
		_controller = VideoPlayerController.networkUrl(
			widget.preview.url,
			videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
		);
		_controller.addListener(() {
			setState(() {});
		});
		_controller.initialize();
	}

	@override
	Widget build(BuildContext context) {
		return _controller.value.isInitialized
				? Container(height: 250, child: AspectRatio(
			aspectRatio: _controller.value.aspectRatio,
			child: Stack(
				alignment: Alignment.bottomCenter,
				children: [
					VideoPlayer(_controller),
					GestureDetector(
						onTap: () async {
							if (_controller.value.isPlaying) {
								await _controller.pause();
							} else {
								await _controller.play();
							}
						},
						child: Center(
							child: Icon(
								_controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
								color: Colors.white.withOpacity(0.7),
								size: 100.0,
							),
						),
					),
					VideoProgressIndicator(
						_controller,
						allowScrubbing: true,
						padding: const EdgeInsets.all(10),
						colors: const VideoProgressColors(
							playedColor: Colors.red,
							bufferedColor: Colors.white24,
							backgroundColor: Colors.grey,
						),
					),
				],
			),
		))
				: Container(
			width: 250,
			height: 250,
			alignment: Alignment.center,
			child: CircularProgressIndicator(),
		);
	}

	@override
	void dispose() {
		_controller.dispose();
		super.dispose();
	}
}
