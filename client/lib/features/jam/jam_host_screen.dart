import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/jam/jam_host_controller.dart';
import '../../core/jam/jam_models.dart';
import '../../core/storage/secure_storage.dart';
import '../../shared/models/track.dart';

ThemeData _jamTheme(ThemeData theme) {
  const targets = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(64, 40)),
    visualDensity: VisualDensity.standard,
    padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
  );
  return theme.copyWith(
    filledButtonTheme: FilledButtonThemeData(
        style: theme.filledButtonTheme.style?.merge(targets) ?? targets),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: theme.outlinedButtonTheme.style?.merge(targets) ?? targets),
    textButtonTheme: TextButtonThemeData(
        style: theme.textButtonTheme.style?.merge(targets) ?? targets),
  );
}

/// Route over an application-owned controller; popping does NOT end hosting.
/// Parent must set visible=false for covered/retained/offstage routes too.
class JamHostScreen extends StatefulWidget {
  const JamHostScreen(
      {super.key, required this.controller, this.visible = true});
  final JamHostController controller;
  final bool visible;
  @override
  State<JamHostScreen> createState() => _JamHostScreenState();
}

class _JamHostScreenState extends State<JamHostScreen> {
  final _selected = <int, Track>{};
  late AuthSessionScope _scope;
  JamHostController get host => widget.controller;
  @override
  void initState() {
    super.initState();
    _scope = host.service.api.captureAuthSession();
    host.service.api.authSessionChanges.addListener(_auth);
    host.setPanelVisible(widget.visible);
  }

  void _auth() {
    if (!host.service.api.acceptsAuthSession(_scope)) {
      _selected.clear();
      _scope = host.service.api.captureAuthSession();
      if (mounted) setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant JamHostScreen old) {
    super.didUpdateWidget(old);
    if (old.controller != host) {
      old.controller.setPanelVisible(false);
      old.controller.service.api.authSessionChanges.removeListener(_auth);
      _scope = host.service.api.captureAuthSession();
      host.service.api.authSessionChanges.addListener(_auth);
      _selected.clear();
    }
    host.setPanelVisible(widget.visible);
  }

  @override
  void dispose() {
    host.service.api.authSessionChanges.removeListener(_auth);
    host.setPanelVisible(false);
    super.dispose();
  }

  Future<void> _choose() async {
    final scope = _scope;
    final result = await showDialog<List<Track>>(
        context: context,
        builder: (_) => Theme(
            data: _jamTheme(Theme.of(context)),
            child: _TrackPicker(
                controller: host,
                selected: _selected.values.toList(),
                scope: scope)));
    if (!mounted ||
        !host.service.api.acceptsAuthSession(scope) ||
        result == null) {
      return;
    }
    setState(() {
      _selected
        ..clear()
        ..addEntries(result.map((t) => MapEntry(t.id, t)));
    });
  }

  Future<void> _origin() async {
    final input =
        TextEditingController(text: host.guestOrigin?.toString() ?? '');
    String? error;
    final value = await showDialog<String>(
        context: context,
        builder: (context) => Theme(
            data: _jamTheme(Theme.of(context)),
            child: StatefulBuilder(
                builder: (context, setLocal) => AlertDialog(
                      title: const Text('Guest web origin'),
                      content: TextField(
                          controller: input,
                          autofocus: true,
                          keyboardType: TextInputType.url,
                          decoration: InputDecoration(
                              hintText: 'https://your-guest-site',
                              errorText: error)),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Cancel')),
                        FilledButton(
                            onPressed: () {
                              try {
                                validateJamOrigin(input.text);
                                Navigator.pop(context, input.text);
                              } catch (_) {
                                setLocal(() => error =
                                    'Enter an HTTPS origin without a path.');
                              }
                            },
                            child: const Text('Save'))
                      ],
                    ))));
    // The dialog route's exit animation may still retain its TextField.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      input.dispose();
    });
    if (value != null && mounted) host.setGuestOrigin(value);
  }

  Future<void> _end() async {
    final end = await showDialog<bool>(
        context: context,
        builder: (c) => Theme(
            data: _jamTheme(Theme.of(c)),
            child: AlertDialog(
                title: const Text('End Jam?'),
                content: const Text(
                    'Guests will no longer be able to request tracks.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Keep hosting')),
                  FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('End Jam'))
                ])));
    if (end == true) await host.end();
  }

  @override
  Widget build(BuildContext context) => Theme(
      data: _jamTheme(Theme.of(context)),
      child: AnimatedBuilder(
          animation: host,
          builder: (context, _) {
            final snapshot = host.snapshot,
                metadata = host.hostMetadata,
                link = host.invitationLink;
            return Scaffold(
                appBar: AppBar(title: const Text('Jam'), actions: [
                  if (host.hasJam)
                    TextButton(
                        onPressed: host.busy ? null : _end,
                        child: const Text('End Jam'))
                ]),
                body: Center(
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: ListView(
                            padding: const EdgeInsets.all(24),
                            children: [
                              if (!host.hasJam) ...[
                                Text('Start a Jam',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineMedium),
                                const SizedBox(height: 12),
                                const Text(
                                    'Choose up to 20 tracks from your library. Guests request; you approve.'),
                                const SizedBox(height: 20),
                                OutlinedButton.icon(
                                    onPressed: host.busy ? null : _choose,
                                    icon: const Icon(
                                        Icons.library_music_outlined),
                                    label: const Text('Choose tracks')),
                                if (_selected.isNotEmpty)
                                  Text(
                                      '${_selected.length} ${_selected.length == 1 ? 'track' : 'tracks'} selected'),
                                for (final t in _selected.values)
                                  ListTile(
                                      title: Text(t.title),
                                      subtitle: Text(t.artist ?? ''),
                                      trailing: IconButton(
                                          tooltip: 'Remove track',
                                          onPressed: () => setState(
                                              () => _selected.remove(t.id)),
                                          icon: const Icon(Icons.close))),
                                FilledButton(
                                    onPressed: _selected.isEmpty || host.busy
                                        ? null
                                        : () =>
                                            host.start(_selected.keys.toList()),
                                    child: const Text('Start Jam')),
                              ] else ...[
                                Text(
                                    snapshot?.state == 'expired'
                                        ? 'Jam expired'
                                        : snapshot?.state == 'closed'
                                            ? 'Jam ended'
                                            : host.isHosting
                                                ? 'Hosting Jam'
                                                : 'Host offline',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineMedium),
                                if (snapshot != null)
                                  Text(
                                      '${snapshot.memberCount} ${snapshot.memberCount == 1 ? 'guest' : 'guests'}'),
                                const SizedBox(height: 16),
                                if (metadata != null)
                                  ListTile(
                                      leading: Icon(metadata.playing
                                          ? Icons.graphic_eq
                                          : Icons.pause),
                                      title: Text(metadata.title),
                                      subtitle: Text(metadata.artist)),
                                const Divider(),
                                Text('Invite guests',
                                    style:
                                        Theme.of(context).textTheme.titleLarge),
                                TextButton(
                                    onPressed: host.busy ? null : _origin,
                                    child: Text(host.guestOrigin?.toString() ??
                                        'Set guest web origin')),
                                FilledButton.icon(
                                    onPressed: host.isHosting && !host.busy
                                        ? () => host.rotateInvite()
                                        : null,
                                    icon: const Icon(Icons.qr_code),
                                    label: Text(link == null
                                        ? 'Create invitation'
                                        : 'New invitation')),
                                if (link != null) ...[
                                  const SizedBox(height: 12),
                                  Center(
                                      child: RepaintBoundary(
                                          key: const ValueKey(
                                              'jam-invitation-qr'),
                                          child: QrImageView(
                                              data: link.toString(),
                                              size: 240,
                                              padding: const EdgeInsets.all(16),
                                              backgroundColor: Colors.white,
                                              errorCorrectionLevel:
                                                  QrErrorCorrectLevel.M,
                                              semanticsLabel:
                                                  'Jam invitation QR code'))),
                                  SelectableText(link.toString()),
                                  TextButton.icon(
                                      onPressed: () => Clipboard.setData(
                                          ClipboardData(text: link.toString())),
                                      icon: const Icon(Icons.copy),
                                      label:
                                          const Text('Copy invitation link')),
                                ],
                                const Divider(),
                                Text('Requests',
                                    style:
                                        Theme.of(context).textTheme.titleLarge),
                                if (snapshot == null ||
                                    snapshot.hostRequests.isEmpty)
                                  const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 16),
                                      child: Text('No requests yet.')),
                                for (final request
                                    in snapshot?.hostRequests ?? <JamRequest>[])
                                  _requestRow(context, request),
                              ],
                              if (host.message != null)
                                Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 16),
                                    child: Text(host.message!)),
                              if (host.hasJam && snapshot == null)
                                TextButton(
                                    onPressed: host.busy
                                        ? null
                                        : () => host.retryStart(),
                                    child: const Text('Retry start')),
                              if (host.hasJam)
                                TextButton.icon(
                                    onPressed:
                                        host.busy ? null : () => host.refresh(),
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Refresh status')),
                              if (host.busy) const LinearProgressIndicator(),
                            ]))));
          }));
  Widget _requestRow(BuildContext context, JamRequest request) {
    final catalog =
        host.snapshot!.catalog.firstWhere((c) => c.id == request.catalogItemId);
    final actionable = {'pending', 'uncertain'}.contains(request.status);
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(catalog.title, style: Theme.of(context).textTheme.titleMedium),
          Text('${request.displayName} · ${catalog.artist}'),
          if (!actionable)
            Text(request.status == 'queued' ? 'Queued' : 'Declined')
          else
            Wrap(spacing: 12, children: [
              if (!host.attempted(request.requestId) &&
                  request.status == 'pending')
                FilledButton(
                    onPressed: host.canApprove
                        ? () => host.approve(request.requestId)
                        : null,
                    child: const Text('Approve')),
              if (host.attempted(request.requestId))
                OutlinedButton(
                    onPressed: host.canApprove
                        ? () => host.reconcileDecision(request.requestId)
                        : null,
                    child: Text(host.hasReceipt(request.requestId)
                        ? 'Confirm queued'
                        : 'Mark uncertain')),
              TextButton(
                  onPressed: host.canApprove
                      ? () => host.decline(request.requestId)
                      : null,
                  child: const Text('Decline')),
            ]),
        ]));
  }
}

class _TrackPicker extends StatefulWidget {
  const _TrackPicker(
      {required this.controller, required this.selected, required this.scope});
  final JamHostController controller;
  final List<Track> selected;
  final AuthSessionScope scope;
  @override
  State<_TrackPicker> createState() => _TrackPickerState();
}

class _TrackPickerState extends State<_TrackPicker> {
  final _query = TextEditingController();
  final _chosen = <int, Track>{};
  List<Track> _tracks = [];
  int _offset = 0, _total = 0, _generation = 0;
  bool _loading = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _chosen.addEntries(widget.selected.map((t) => MapEntry(t.id, t)));
    widget.controller.service.api.authSessionChanges.addListener(_auth);
    unawaited(_load(reset: true));
  }

  void _auth() {
    if (!widget.controller.service.api.acceptsAuthSession(widget.scope)) {
      _generation++;
      _chosen.clear();
      _tracks = [];
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _load({bool reset = false}) async {
    if (!widget.controller.service.api.acceptsAuthSession(widget.scope)) return;
    final gen = ++_generation;
    if (reset) _offset = 0;
    setState(() => _loading = true);
    try {
      final page = await widget.controller
          .libraryPage(offset: _offset, query: _query.text);
      if (!mounted ||
          gen != _generation ||
          !widget.controller.service.api.acceptsAuthSession(widget.scope)) {
        return;
      }
      setState(() {
        _tracks = reset ? page.tracks : [..._tracks, ...page.tracks];
        _offset += page.tracks.length;
        _total = page.total;
        _error = null;
      });
    } catch (_) {
      if (mounted && gen == _generation) {
        setState(() => _error = 'Could not load your library.');
      }
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    widget.controller.service.api.authSessionChanges.removeListener(_auth);
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text('Choose tracks · ${_chosen.length}/20'),
          content: SizedBox(
              width: 560,
              height: 420,
              child: Column(children: [
                TextField(
                    controller: _query,
                    onSubmitted: (_) => _load(reset: true),
                    decoration: InputDecoration(
                        hintText: 'Search your library',
                        suffixIcon: IconButton(
                            tooltip: 'Search library',
                            onPressed:
                                _loading ? null : () => _load(reset: true),
                            icon: const Icon(Icons.search)))),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null) Text(_error!),
                Expanded(
                    child: ListView(children: [
                  for (final track in _tracks)
                    CheckboxListTile(
                        value: _chosen.containsKey(track.id),
                        title: Text(track.title),
                        subtitle: Text(track.artist ?? ''),
                        onChanged: _loading ||
                                (!_chosen.containsKey(track.id) &&
                                    _chosen.length >= 20)
                            ? null
                            : (selected) => setState(() {
                                  if (selected == true) {
                                    _chosen[track.id] = track;
                                  } else {
                                    _chosen.remove(track.id);
                                  }
                                })),
                  if (_tracks.isEmpty && !_loading)
                    const ListTile(title: Text('No library tracks found.')),
                  if (_offset < _total)
                    TextButton(
                        onPressed: _loading ? null : () => _load(),
                        child: const Text('Load more')),
                ])),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: _chosen.isEmpty
                    ? null
                    : () => Navigator.pop(context, _chosen.values.toList()),
                child: Text(
                    'Use ${_chosen.length} ${_chosen.length == 1 ? 'track' : 'tracks'}'))
          ]);
}
