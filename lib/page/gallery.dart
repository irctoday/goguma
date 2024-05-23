import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

class GalleryPageArguments {
	final Uri uri;
	final Object heroTag;

	const GalleryPageArguments({
		required this.uri,
		required this.heroTag,
	});
}

class GalleryPage extends StatefulWidget {
	static const routeName = '/buffer/gallery';

	final Uri uri;
	final Object heroTag;

	const GalleryPage({ super.key, required this.uri, required this.heroTag });

	@override
	State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
	@override
	Widget build(BuildContext context) {
		return Scaffold(
			appBar: AppBar(
				backgroundColor: Colors.black,
				actions: [
					IconButton(
						tooltip: 'Share',
						icon: const Icon(Icons.share),
						onPressed: () {
							Share.shareUri(widget.uri);
						},
					),
				],
			),
			backgroundColor: Colors.black,
			body: Hero(tag: widget.heroTag, child: Image.network(
				widget.uri.toString(),
				filterQuality: FilterQuality.medium,
				loadingBuilder: (context, child, loadingProgress) {
					if (loadingProgress == null) {
						return InteractiveViewer(
							child: Center(child: child),
						);
					}
					double? progress;
					if (loadingProgress.expectedTotalBytes != null) {
						progress = loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!;
					}
					return Center(child: CircularProgressIndicator(
						value: progress,
						color: Colors.white,
					));
				},
				errorBuilder: (context, error, stackTrace) {
					return Center(child: Column(
						mainAxisAlignment: MainAxisAlignment.center,
						children: [
							Icon(Icons.error, color: Colors.white),
							Text(error.toString(), style: TextStyle(color: Colors.white)),
						],
					));
				},
			)),
		);
	}
}
