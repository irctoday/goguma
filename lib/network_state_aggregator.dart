import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'models.dart';

class NetworkStateAggregator extends ChangeNotifier {
	final NetworkListModel _networkList;
	final List<_NetworkStateListener> _listeners = [];
	late NetworkState _state;
	Set<NetworkModel> _faultyNetworks = {};

	NetworkStateAggregator(NetworkListModel networkList) : _networkList = networkList {
		_networkList.addListener(_handleNetworkListChange);
		_addNetworkListeners();
		_update(true);
	}

	NetworkState get state => _state;
	Set<NetworkModel> get faultyNetworks => UnmodifiableSetView(_faultyNetworks);

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
		Set<NetworkModel> faultyNetworks = {};
		for (var network in _networkList.networks) {
			if (network.state.index < NetworkState.online.index) {
				faultyNetworks.add(network);
			}
			if (network.state.index < aggregateState.index) {
				aggregateState = network.state;
			}
		}

		if (force || _state != aggregateState || !setEquals(_faultyNetworks, faultyNetworks)) {
			_state = aggregateState;
			_faultyNetworks = faultyNetworks;
			notifyListeners();
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
