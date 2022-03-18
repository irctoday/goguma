import 'package:flutter/material.dart';

import '../models.dart';
import '../network_state_aggregator.dart';

class NetworkListIndicator extends StatefulWidget {
	final Widget child;
	final NetworkListModel networkList;

	const NetworkListIndicator({ Key? key, required this.child, required this.networkList }) : super(key: key);

	@override
	_NetworkListIndicatorState createState() => _NetworkListIndicatorState();
}

class _NetworkListIndicatorState extends State<NetworkListIndicator> {
	final _refreshIndicatorKey = GlobalKey<_RefreshIndicatorState>();
	late final NetworkStateAggregator _networkStateAggregator;

	@override
	void initState() {
		super.initState();

		_networkStateAggregator = NetworkStateAggregator(widget.networkList);
		_networkStateAggregator.addListener(_handleNetworkStateChange);
	}

	@override
	void dispose() {
		_networkStateAggregator.removeListener(_handleNetworkStateChange);
		_networkStateAggregator.dispose();
		super.dispose();
	}

	void _handleNetworkStateChange() {
		var state = _networkStateAggregator.state;
		var loading = state != NetworkState.offline && state != NetworkState.online;
		_refreshIndicatorKey.currentState!.setLoading(loading);
	}

	@override
	Widget build(BuildContext context) {
		return _RefreshIndicator(
			key: _refreshIndicatorKey,
			semanticsLabel: 'Synchronizing…',
			child: widget.child,
		);
	}
}

class NetworkIndicator extends StatefulWidget {
	final Widget child;
	final NetworkModel network;

	const NetworkIndicator({ Key? key, required this.child, required this.network }) : super(key: key);

	@override
	_NetworkIndicatorState createState() => _NetworkIndicatorState();
}

class _NetworkIndicatorState extends State<NetworkIndicator> {
	final _refreshIndicatorKey = GlobalKey<_RefreshIndicatorState>();

	@override
	void initState() {
		super.initState();
		widget.network.addListener(_handleNetworkChange);
	}

	@override
	void dispose() {
		widget.network.removeListener(_handleNetworkChange);
		super.dispose();
	}

	void _handleNetworkChange() {
		var state = widget.network.state;
		var loading = state != NetworkState.offline && state != NetworkState.online;
		_refreshIndicatorKey.currentState!.setLoading(loading);
	}

	@override
	Widget build(BuildContext context) {
		return _RefreshIndicator(
			key: _refreshIndicatorKey,
			semanticsLabel: 'Synchronizing…',
			child: widget.child,
		);
	}
}

class _RefreshIndicator extends StatefulWidget {
	final Widget child;
	final String? semanticsLabel;

	const _RefreshIndicator({ Key? key, required this.child, this.semanticsLabel }) : super(key: key);

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
	}

	@override
	void dispose() {
		_scaleController.dispose();
		super.dispose();
	}

	void setLoading(bool loading) {
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
