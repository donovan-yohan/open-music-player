import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_state.dart';
import '../../core/connect/connect_service.dart';
import '../../core/storage/secure_storage.dart';
import 'device_panel.dart';

/// A stable account admission for this route, independent of rebuilds. Modal
/// routes include dialogs, so covering a still-mounted panel cancels its poll.
class ConnectedDevicesScreen extends StatefulWidget {
  const ConnectedDevicesScreen({super.key, required this.routeObserver});

  final RouteObserver<ModalRoute<dynamic>> routeObserver;

  @override
  State<ConnectedDevicesScreen> createState() => _ConnectedDevicesScreenState();
}

class _ConnectedDevicesScreenState extends State<ConnectedDevicesScreen>
    with RouteAware {
  late final ConnectService _service;
  AuthSessionScope? _scope;
  int? _revision;
  ModalRoute<dynamic>? _route;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _service = context.read<ConnectService>();
    final auth = context.read<AuthState>();
    if (auth.isAuthenticated && !auth.isLoading) {
      final scope = _service.api.captureAuthSession();
      if (_service.api.acceptsAuthSession(scope)) {
        _scope = scope;
        _revision = auth.sessionRevision;
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _route) return;
    widget.routeObserver.unsubscribe(this);
    _route = route;
    _visible = route?.isCurrent ?? false;
    if (route != null) widget.routeObserver.subscribe(this, route);
  }

  @override
  void didPush() => _setVisible(true);
  @override
  void didPopNext() => _setVisible(true);
  @override
  void didPushNext() => _setVisible(false);
  @override
  void didPop() => _setVisible(false);

  void _setVisible(bool value) {
    if (mounted && value != _visible) setState(() => _visible = value);
  }

  @override
  void dispose() {
    widget.routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    final scope = _scope;
    return Scaffold(
      appBar: AppBar(title: const Text('Connected devices')),
      body: scope != null &&
              auth.isAuthenticated &&
              auth.sessionRevision == _revision
          ? DevicePanel(service: _service, scope: scope, visible: _visible)
          : const Center(child: Text('Sign in to view connected devices.')),
    );
  }
}
