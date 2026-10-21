import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/jam/jam_host_controller.dart';
import 'jam_host_screen.dart';

/// Route visibility only. The application retains the host and its heartbeat.
class JamRouteScreen extends StatefulWidget {
  const JamRouteScreen({super.key, required this.routeObserver});
  final RouteObserver<ModalRoute<dynamic>> routeObserver;

  @override
  State<JamRouteScreen> createState() => _JamRouteScreenState();
}

class _JamRouteScreenState extends State<JamRouteScreen> with RouteAware {
  ModalRoute<dynamic>? _route;
  bool _visible = false;

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

  void _setVisible(bool value) {
    if (mounted && _visible != value) setState(() => _visible = value);
  }

  @override
  void didPush() => _setVisible(true);
  @override
  void didPopNext() => _setVisible(true);
  @override
  void didPushNext() => _setVisible(false);
  @override
  void didPop() => _setVisible(false);

  @override
  void dispose() {
    widget.routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => JamHostScreen(
      controller: context.read<JamHostController>(), visible: _visible);
}
