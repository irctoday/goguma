import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models.dart';
import 'network-state-aggregator.dart';

class NetworkListIndicator extends StatefulWidget {
	final Widget child;
	final NetworkListModel networkList;

	NetworkListIndicator({ Key? key, required this.child, required NetworkListModel this.networkList }) : super(key: key);

	@override
	NetworkListIndicatorState createState() => NetworkListIndicatorState();
}

class NetworkListIndicatorState extends State<NetworkListIndicator> with SingleTickerProviderStateMixin<NetworkListIndicator> {
	late final NetworkStateAggregator _networkStateAggregator;
	late final AnimationController _scaleController = AnimationController(vsync: this, duration: Duration(milliseconds: 200));
	late final Animation<double> _scale = _scaleController.drive(Tween<double>(begin: 0.0, end: 1.0));
	bool _loading = false;

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
		_scaleController.dispose();
		super.dispose();
	}

	void _handleNetworkStateChange() {
		var state = _networkStateAggregator.state;
		var loading = state != NetworkState.offline && state != NetworkState.online;
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
		return Stack(children: [
			widget.child,
			if (_loading) Container(
				padding: EdgeInsets.only(top: 20),
				alignment: Alignment.topCenter,
				child: ScaleTransition(
					scale: _scale,
					child: RefreshProgressIndicator(semanticsLabel: 'Synchronizing…'),
				),
			),
		]);
	}
}
