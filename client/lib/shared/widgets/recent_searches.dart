import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_state.dart';
import '../../core/storage/search_history.dart';

/// History is visible only while the empty search field has focus. Listening to
/// the field itself also handles programmatic clears and chip selections.
class RecentSearches extends StatefulWidget {
  const RecentSearches({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.store,
    required this.onSelected,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final SearchHistoryStore store;
  final ValueChanged<String> onSelected;

  @override
  State<RecentSearches> createState() => _RecentSearchesState();
}

class _RecentSearchesState extends State<RecentSearches> {
  List<String> _queries = const [];
  bool _visible = false;
  int _request = 0;
  (int, bool)? _session;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_fieldChanged);
    widget.focusNode.addListener(_fieldChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthState?>();
    final session = auth == null
        ? null
        : (auth.sessionRevision, auth.isAuthenticated && !auth.isLoading);
    if (session != _session) {
      _session = session;
      _visible = false;
      _queries = const [];
      _request++;
    }
    _fieldChanged();
  }

  void _fieldChanged() {
    final visible = widget.focusNode.hasFocus &&
        widget.controller.text.trim().isEmpty &&
        (_session?.$2 ?? true);
    if (visible == _visible) return;
    setState(() {
      _visible = visible;
      _queries = const [];
    });
    final request = ++_request;
    if (visible) unawaited(_load(request));
  }

  Future<void> _load(int request) async {
    final queries = await widget.store.load();
    if (!mounted || request != _request) return;
    setState(() => _queries = queries);
  }

  Future<void> _clear() async {
    final request = ++_request;
    setState(() => _queries = const []);
    await widget.store.clear();
    if (mounted && request == _request && _visible) await _load(request);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_fieldChanged);
    widget.focusNode.removeListener(_fieldChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible || _queries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Recent searches',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            IconButton(
              tooltip: 'Clear history',
              onPressed: _clear,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        LayoutBuilder(builder: (context, constraints) {
          // Discover dismisses its keyboard on vertical drags. Keep horizontal
          // updates local so swiping history cannot hide the focused shelf.
          return NotificationListener<ScrollUpdateNotification>(
            onNotification: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              key: ValueKey('recent_searches_${widget.store.kind.name}'),
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.hardEdge,
              child: Row(
                children: [
                  for (var i = 0; i < _queries.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.min(160, constraints.maxWidth * 0.42),
                      ),
                      child: Tooltip(
                        message: _queries[i],
                        child: ActionChip(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          label: Text(
                            _queries[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onPressed: () => widget.onSelected(_queries[i]),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}
