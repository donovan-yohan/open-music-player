import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The furthest the row is ever allowed to slide, in logical pixels. The
/// resistance curve only approaches this asymptotically, so the row cannot
/// reach it however hard the finger pulls.
const double _maxTravel = 96;

/// A narrow row would read as a dismissal long before it moved [_maxTravel],
/// so the travel is also capped to a slice of the row's own width.
const double _maxTravelWidthFraction = 0.32;

/// Share of the available travel at which releasing queues the track. Much
/// lower and the gesture arms before the finger has felt any resistance; much
/// higher and the arm point sits in the stiff tail, where the row has stopped
/// visibly answering the finger and the swipe feels like it never triggers.
const double _activationFraction = 0.58;

/// Width reserved for the queue icon inside the revealed gap. The icon keeps
/// this size and is cropped by the gap rather than squeezed into it.
const double _revealIconSlot = 56;

const Duration _springBackDuration = Duration(milliseconds: 220);
const Curve _springBackCurve = Curves.easeOutCubic;

/// Rubber band: `travel = maxTravel * (1 - e^(-drag / maxTravel))`.
///
/// Using the travel cap as the decay constant makes the first pixels follow
/// the finger one for one, which is what stops the row feeling stuck at the
/// start of the swipe. Resistance then builds smoothly: by the time the action
/// arms the finger is moving about 2.4x faster than the row, which both sells
/// the spring and damps pointer jitter around the activation point.
double _resist(double drag, double maxTravel) {
  if (drag <= 0 || maxTravel <= 0) return 0;
  return maxTravel * (1 - math.exp(-drag / maxTravel));
}

/// Inverse of [_resist], used to recover the drag distance a given travel
/// represents when the finger grabs a row that is still springing back.
double _unresist(double travel, double maxTravel) {
  if (travel <= 0 || maxTravel <= 0) return 0;
  final ratio = math.min(travel / maxTravel, 0.999);
  return -maxTravel * math.log(1 - ratio);
}

/// Wraps a track row with a springy swipe-to-queue gesture.
///
/// This deliberately does not use [Dismissible]. That widget tracks the finger
/// one for one across the whole row because its job is to carry the row off
/// screen, which is the wrong promise here: the row is staying, only the queue
/// gains a track. Instead the travel is capped and rubber-banded, the row
/// springs back on release, and a light haptic marks the point where letting
/// go would fire the action.
class QueueSwipeAction extends StatefulWidget {
  const QueueSwipeAction({
    super.key,
    required this.actionKey,
    required this.onAddToQueue,
    required this.child,
    this.enabled = true,
    this.onSecondaryTapUp,
  });

  final Key actionKey;
  final Future<void> Function() onAddToQueue;
  final Widget child;
  final bool enabled;
  final GestureTapUpCallback? onSecondaryTapUp;

  @override
  State<QueueSwipeAction> createState() => _QueueSwipeActionState();
}

class _QueueSwipeActionState extends State<QueueSwipeAction>
    with SingleTickerProviderStateMixin {
  /// Unbounded because the drag writes travel in logical pixels straight into
  /// it; the spring-back then animates the same value home. Created eagerly so
  /// a disabled row, which never builds the gesture, still has something safe
  /// to dispose.
  late final AnimationController _travel;

  TextDirection _textDirection = TextDirection.ltr;

  /// Raw finger distance toward the end edge, before resistance.
  double _drag = 0;

  /// Resolved for the row that is actually on screen, so a narrow row gets a
  /// proportionally shorter swipe instead of an outsized one.
  double _travelLimit = _maxTravel;

  /// Whether releasing right now would queue the track.
  bool _armed = false;

  double get _activationTravel => _travelLimit * _activationFraction;

  /// Sign that carries the row toward the end edge, so the gesture reads the
  /// same way under RTL as `DismissDirection.startToEnd` used to.
  double get _towardEnd => _textDirection == TextDirection.rtl ? -1 : 1;

  @override
  void initState() {
    super.initState();
    _travel = AnimationController.unbounded(vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _textDirection = Directionality.maybeOf(context) ?? TextDirection.ltr;
  }

  @override
  void dispose() {
    _travel.dispose();
    super.dispose();
  }

  void _handleDragStart(DragStartDetails details) {
    final width = context.size?.width ?? 0;
    _travelLimit = width > 0
        ? math.min(_maxTravel, width * _maxTravelWidthFraction)
        : _maxTravel;
    // Grabbing a row that is still springing back should pick it up where it
    // is rather than snap it to rest under the finger.
    _drag = _unresist(_travel.value, _travelLimit);
    _armed = _travel.value >= _activationTravel;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _drag = math.max(0, _drag + (details.primaryDelta ?? 0) * _towardEnd);
    _travel.value = _resist(_drag, _travelLimit);

    final armed = _travel.value >= _activationTravel;
    if (armed == _armed) return;
    _armed = armed;
    // Falling back below the line disarms, and pulling past it again buzzes
    // again: each crossing is a fresh commitment, and a single silent re-cross
    // would leave the user unsure whether the action is still loaded.
    if (armed) _tick();
  }

  void _handleDragEnd(DragEndDetails details) {
    final fire = _armed;
    _reset();
    // Velocity deliberately does not fire on its own: without a crossing there
    // was no haptic, so a flick that queued a track would come out of nowhere.
    if (fire) unawaited(widget.onAddToQueue());
  }

  void _handleDragCancel() => _reset();

  void _reset() {
    _drag = 0;
    _armed = false;
    if (_travel.value == 0) return;
    _travel.animateTo(
      0,
      duration: _springBackDuration,
      curve: _springBackCurve,
    );
  }

  void _tick() {
    // Web has no haptics channel at all; every other platform no-ops quietly
    // when the device cannot buzz.
    if (kIsWeb) return;
    unawaited(HapticFeedback.lightImpact());
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final theme = Theme.of(context);
    // Built once per build, not per drag frame, and handed unchanged to the
    // builder below so its element subtree is never rebuilt mid-gesture.
    final reveal = ClipRect(
      child: ColoredBox(
        color: theme.colorScheme.primaryContainer,
        child: OverflowBox(
          alignment: AlignmentDirectional.centerEnd,
          minWidth: _revealIconSlot,
          maxWidth: _revealIconSlot,
          child: Icon(
            Icons.queue_music,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
      ),
    );

    return GestureDetector(
      key: widget.actionKey,
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: widget.onSecondaryTapUp,
      // Horizontal recognizers only, so a vertical drag is never contested and
      // the enclosing list keeps scrolling exactly as it did before.
      onHorizontalDragStart: _handleDragStart,
      onHorizontalDragUpdate: _handleDragUpdate,
      onHorizontalDragEnd: _handleDragEnd,
      onHorizontalDragCancel: _handleDragCancel,
      child: AnimatedBuilder(
        animation: _travel,
        child: widget.child,
        builder: (context, child) => Stack(
          children: [
            // The gap the row opens is the only tinted area, so the row itself
            // never sits under a wash of color on a short swipe.
            Positioned.directional(
              textDirection: _textDirection,
              start: 0,
              top: 0,
              bottom: 0,
              width: _travel.value,
              child: reveal,
            ),
            Transform.translate(
              offset: Offset(_travel.value * _towardEnd, 0),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}
