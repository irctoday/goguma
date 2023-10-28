import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

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
				return builder(context, _PhotoPreview(preview));
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
					bool ok = await launchUrl(preview.url, mode: LaunchMode.externalApplication);
					if (!ok) {
						throw Exception('Failed to launch URL: ${preview.url}');
					}
				}
			},
			child: Hero(tag: _heroTag, child: Image.network(
				preview.imageUrl.toString(),
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
