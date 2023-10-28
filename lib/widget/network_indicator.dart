import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../network_state_aggregator.dart';

class NetworkListIndicator extends StatefulWidget {
	final Widget child;

	const NetworkListIndicator({ super.key, required this.child });

	@override
	State<NetworkListIndicator> createState() => _NetworkListIndicatorState();
}

class _NetworkListIndicatorState extends State<NetworkListIndicator> {
	late final NetworkStateAggregator _networkStateAggregator;

	@override
	void initState() {
		super.initState();

		var networkList = context.read<NetworkListModel>();
		_networkStateAggregator = NetworkStateAggregator(networkList);
	}

	@override
	void dispose() {
		_networkStateAggregator.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		return AnimatedBuilder(
			animation: _networkStateAggregator,
			builder: (context, child) {
				var state = _networkStateAggregator.state;
				var loading = state != NetworkState.offline && state != NetworkState.online;
				return _RefreshIndicator(
					loading: loading,
					semanticsLabel: 'Synchronizing…',
					child: child!,
				);
			},
			child: widget.child,
		);
	}
}

class NetworkIndicator extends AnimatedWidget {
	final Widget child;
	final NetworkModel network;

	const NetworkIndicator({
		super.key,
		required this.child,
		required this.network,
	}) : super(listenable: network);

	@override
	Widget build(BuildContext context) {
		var loading = network.state != NetworkState.offline && network.state != NetworkState.online;
		return _RefreshIndicator(
			loading: loading,
			semanticsLabel: 'Synchronizing…',
			child: child,
		);
	}
}

class _RefreshIndicator extends StatefulWidget {
	final Widget child;
	final bool loading;
	final String? semanticsLabel;

	const _RefreshIndicator({
		required this.child,
		required this.loading,
		this.semanticsLabel,
	});

	@override
	_RefreshIndicatorState createState() => _RefreshIndicatorState();
}

class _RefreshIndicatorState extends State<_RefreshIndicator> with SingleTickerProviderStateMixin<_RefreshIndicator> {
	late final AnimationController _scaleController;
	late final Animation<double> _scale;
	bool _loading = false;

	@override
	void initState() {
		super.initState();

		_scaleController = AnimationController(vsync: this, duration: Duration(milliseconds: 200));
		_scale = _scaleController.drive(Tween<double>(begin: 0.0, end: 1.0));

		_setLoading(widget.loading);
	}

	@override
	void dispose() {
		_scaleController.dispose();
		super.dispose();
	}

	@override
	void didUpdateWidget(_RefreshIndicator oldWidget) {
		super.didUpdateWidget(oldWidget);
		_setLoading(widget.loading);
	}

	void _setLoading(bool loading) {
		if (_loading == loading) {
			return;
		}

		if (loading) {
			setState(() {
				_loading = true;
			});
		}

		_scaleController.animateTo(loading ? 1 : 0).then((_) {
			if (!loading) {
				setState(() {
					_loading = false;
				});
			}
		});
	}

	@override
	Widget build(BuildContext context) {
		if (!_loading) {
			return widget.child;
		}

		return Stack(children: [
			widget.child,
			Container(
				padding: EdgeInsets.only(top: 20),
				alignment: Alignment.topCenter,
				child: ScaleTransition(
					scale: _scale,
					child: RefreshProgressIndicator(semanticsLabel: widget.semanticsLabel),
				),
			),
		]);
	}
}
