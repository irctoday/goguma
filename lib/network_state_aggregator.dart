import 'package:flutter/material.dart';

import 'models.dart';

class NetworkStateAggregator extends ChangeNotifier {
	final NetworkListModel _networkList;
	final List<_NetworkStateListener> _listeners = [];
	late NetworkState _state;
	NetworkModel? _faultyNetwork;

	NetworkStateAggregator(NetworkListModel networkList) : _networkList = networkList {
		_networkList.addListener(_handleNetworkListChange);
		_addNetworkListeners();
		_update(true);
	}

	NetworkState get state => _state;
	NetworkModel? get faultyNetwork => _faultyNetwork;

	void _addNetworkListeners() {
		for (var network in _networkList.networks) {
			_listeners.add(_NetworkStateListener(network, _handleNetworkStatusChange));
		}
	}

	void _removeNetworkListeners() {
		for (var l in _listeners) {
			l.cancel();
		}
		_listeners.clear();
	}

	void _handleNetworkListChange() {
		_removeNetworkListeners();
		_addNetworkListeners();
		_update(false);
	}

	void _handleNetworkStatusChange() {
		_update(false);
	}

	void _update(bool force) {
		NetworkState aggregateState = NetworkState.online;
		NetworkModel? faultyNetwork;
		for (var network in _networkList.networks) {
			if (_networkStateToInt(network.state) < _networkStateToInt(aggregateState)) {
				aggregateState = network.state;
				faultyNetwork = network;
			}
		}

		if (force || _state != aggregateState) {
			_state = aggregateState;
			_faultyNetwork = faultyNetwork;
			notifyListeners();
		}
	}

	int _networkStateToInt(NetworkState state) {
		switch (state) {
		case NetworkState.offline:
			return 0;
		case NetworkState.connecting:
			return 1;
		case NetworkState.registering:
			return 2;
		case NetworkState.synchronizing:
			return 3;
		case NetworkState.online:
			return 4;
		}
	}

	@override
	void dispose() {
		_removeNetworkListeners();
		_networkList.removeListener(_handleNetworkListChange);
		super.dispose();
	}
}

class _NetworkStateListener {
	final NetworkModel network;
	final void Function() onChange;
	NetworkState _prevState;

	_NetworkStateListener(this.network, this.onChange) : _prevState = network.state {
		network.addListener(_handleChange);
	}

	void cancel() {
		network.removeListener(_handleChange);
	}

	void _handleChange() {
		if (network.state != _prevState) {
			_prevState = network.state;
			onChange();
		}
	}
}
