import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../link_preview.dart';
import '../page/gallery.dart';

typedef LinkPreviewBuilder = Widget Function(BuildContext context, Widget child);

class LinkPreview extends StatelessWidget {
	final String text;
	final LinkPreviewBuilder builder;

	const LinkPreview({
		required this.text,
		required this.builder,
		Key? key,
	}) : super(key: key);

	@override
	Widget build(BuildContext context) {
		var linkPreviewer = context.read<LinkPreviewer>();
		// Try to populate the initial data from cache, to avoid jitter in
		// the UI
		var cached = linkPreviewer.cachedPreviewText(text);
		Future<List<PhotoPreview>>? future;
		if (cached == null) {
			future = linkPreviewer.previewText(text);
		}
		return FutureBuilder<List<PhotoPreview>>(
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
	final PhotoPreview preview;
	final Object _heroTag;

	_PhotoPreview(this.preview, { Key? key }) : _heroTag = Object(), super(key: key);

	@override
	Widget build(BuildContext context) {
		return InkWell(
			onTap: () {
				Navigator.pushNamed(context, GalleryPage.routeName, arguments: GalleryPageArguments(
					uri: preview.url,
					heroTag: _heroTag,
				));
			},
			child: Hero(tag: _heroTag, child: Image.network(
				preview.url.toString(),
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
