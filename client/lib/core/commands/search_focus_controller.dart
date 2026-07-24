import 'package:flutter/widgets.dart';

/// Injected bridge between the app-level Focus Search command and the routed
/// search field. It owns no query or navigation state.
class SearchFocusController {
  FocusNode? _focusNode;
  bool _pendingRequest = false;

  void register(FocusNode focusNode) {
    _focusNode = focusNode;
    if (_pendingRequest) {
      _pendingRequest = false;
      focusNode.requestFocus();
    }
  }

  void unregister(FocusNode focusNode) {
    if (identical(_focusNode, focusNode)) _focusNode = null;
  }

  void requestFocus() {
    final node = _focusNode;
    if (node == null) {
      _pendingRequest = true;
      return;
    }
    node.requestFocus();
  }
}
