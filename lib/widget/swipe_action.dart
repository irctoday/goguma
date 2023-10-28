import 'package:flutter/widgets.dart';

class SwipeAction extends StatefulWidget {
	final Widget child;
	final VoidCallback? onSwipe;
	final Widget? background;

	const SwipeAction({ super.key, required this.child, this.onSwipe, this.background });

	@override
	State<SwipeAction> createState() => _SwipeActionState();
}

class _SwipeActionState extends State<SwipeAction> with TickerProviderStateMixin {
	late final AnimationController _moveController;
	late final Animation<Offset> _moveAnimation;

	double _dragExtent = 0;
	final double _maxDragExtent = 50;

	@override
	void initState() {
		super.initState();
		_moveController = AnimationController(duration: Duration(milliseconds: 200), vsync: this);
		_moveAnimation = _moveController.drive(Tween<Offset>(begin: Offset.zero, end: Offset(1, 0)));
	}

	@override
	void dispose() {
		_moveController.dispose();
		super.dispose();
	}

	void _handleDragStart(DragStartDetails details) {
		if (_moveController.isAnimating) {
			_moveController.stop();
		}
		_dragExtent = 0.0;
		_moveController.value = 0.0;
	}

	void _handleDragUpdate(DragUpdateDetails details) {
		if (_moveController.isAnimating) {
			return;
		}

		var delta = details.primaryDelta!;
		_dragExtent += delta;
		if (_dragExtent > _maxDragExtent) {
			_dragExtent = _maxDragExtent;
		}
		_moveController.value = _dragExtent / context.size!.width;
	}

	void _handleDragEnd(DragEndDetails details) {
		if (_moveController.isAnimating) {
			return;
		}
		_moveController.reverse();
		if (_dragExtent == _maxDragExtent) {
			widget.onSwipe?.call();
		}
	}

	@override
	Widget build(BuildContext context) {
		if (widget.onSwipe == null) {
			return widget.child;
		}

		Widget content = SlideTransition(
			position: _moveAnimation,
			child: widget.child,
		);

		if (widget.background != null) {
			content = Stack(children: [
				Positioned.fill(child: ClipRect(
					clipper: _SwipeActionClipper(_moveAnimation),
					child: widget.background!),
				),
				content,
			]);
		}

		return GestureDetector(
			child: content,
			onHorizontalDragStart: _handleDragStart,
			onHorizontalDragUpdate: _handleDragUpdate,
			onHorizontalDragEnd: _handleDragEnd,
		);
	}
}

class _SwipeActionClipper extends CustomClipper<Rect> {
	final Animation<Offset> moveAnimation;

	_SwipeActionClipper(this.moveAnimation) : super(reclip: moveAnimation);

	@override
	Rect getClip(Size size) {
		var offset = moveAnimation.value.dx * size.width;
		return Rect.fromLTRB(0.0, 0.0, offset, size.height);
	}

	@override
	Rect getApproximateClipRect(Size size) => getClip(size);

	@override
	bool shouldReclip(_SwipeActionClipper oldClipper) {
		return oldClipper.moveAnimation.value != moveAnimation.value;
	}
}
