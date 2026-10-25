import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Shared authentication composition; credentials keep their native text scale.
class AuthFrame extends StatefulWidget {
  const AuthFrame(
      {super.key, required this.title, required this.child, this.back});

  final String title;
  final Widget child;
  final Widget? back;

  @override
  State<AuthFrame> createState() => _AuthFrameState();
}

class _AuthFrameState extends State<AuthFrame>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // Finite paint-only entrance, never a battery-consuming background loop.
  late final AnimationController _opening = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final Animation<double> _ease = CurvedAnimation(
    parent: _opening,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  bool get _active =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  void _syncMotion() {
    if (MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context) ||
        !TickerMode.valuesOf(context).enabled ||
        !_active) {
      _opening.stop();
      _opening.value = 1;
    } else if (_opening.value < 1 && !_opening.isAnimating) {
      _opening.forward();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncMotion();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    (_ease as CurvedAnimation).dispose();
    _opening.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final desktop = MediaQuery.sizeOf(context).width >= 960;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
              child: IgnorePointer(
                  child: ExcludeSemantics(
                      child: RepaintBoundary(
            child: CustomPaint(
                key: const ValueKey('auth-atmosphere'),
                painter: _SoundContours(
                  progress: _ease,
                  background: theme.scaffoldBackgroundColor,
                  amber: colors.primary,
                  dark: theme.brightness == Brightness.dark,
                )),
          )))),
          SafeArea(
            child: LayoutBuilder(builder: (context, constraints) {
              final compact = constraints.maxWidth < 600;
              return SingleChildScrollView(
                padding: EdgeInsets.all(compact ? 16 : 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - (compact ? 32 : 48))
                        .clamp(0, double.infinity),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.scaffoldBackgroundColor,
                          border: Border.all(color: colors.outline),
                          borderRadius: desktop
                              ? BorderRadius.zero
                              : BorderRadius.circular(16),
                          boxShadow: desktop
                              ? null
                              : [
                                  BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: .18),
                                      blurRadius: 48,
                                      offset: const Offset(0, 20))
                                ],
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(compact ? 20 : 28),
                          child: Theme(
                            data: theme.copyWith(
                              inputDecorationTheme:
                                  theme.inputDecorationTheme.copyWith(
                                isDense: true,
                                floatingLabelBehavior:
                                    FloatingLabelBehavior.always,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 16),
                                errorMaxLines: 3,
                                helperMaxLines: 3,
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(children: [
                                  ClipRRect(
                                    borderRadius: desktop
                                        ? BorderRadius.zero
                                        : BorderRadius.circular(10),
                                    child: Image.asset(
                                        'assets/brand/soundq-logo.png',
                                        width: 52,
                                        height: 52,
                                        excludeFromSemantics: true),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                      child: Text('Sound Q',
                                          style: theme.textTheme.titleLarge
                                              ?.copyWith(
                                                  fontSize: 20,
                                                  fontWeight:
                                                      FontWeight.w800))),
                                  if (widget.back != null) widget.back!,
                                ]),
                                const SizedBox(height: 28),
                                Text(widget.title,
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(
                                            fontSize: 24,
                                            fontWeight: FontWeight.w700)),
                                const SizedBox(height: 24),
                                AutofillGroup(child: widget.child),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _SoundContours extends CustomPainter {
  _SoundContours(
      {required this.progress,
      required this.background,
      required this.amber,
      required this.dark})
      : super(repaint: progress);

  final Animation<double> progress;
  final Color background;
  final Color amber;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawColor(background, BlendMode.src);
    // Warm, asymmetric light and contour ribbons frame rather than fill the form.
    final center = Offset(size.width * .16, size.height * .30);
    canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            center,
            size.longestSide * .68,
            [
              amber.withValues(alpha: dark ? .12 : .065),
              amber.withValues(alpha: 0)
            ],
          ));
    canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            Offset(size.width * .92, size.height * .90),
            size.longestSide * .54,
            [
              const Color(0xFFA9552C).withValues(alpha: dark ? .13 : .05),
              Colors.transparent
            ],
          ));
    final shift = (1 - progress.value) * 12;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8;
    for (var side = 0; side < 2; side++) {
      canvas.save();
      if (side == 1) {
        canvas.translate(size.width, size.height);
        canvas.rotate(3.141592653589793);
      }
      for (var i = 0; i < 16; i++) {
        final x = size.width * .07 + i * 13 + shift;
        final path = Path()
          ..moveTo(x - 200, -40)
          ..cubicTo(x + 260, size.height * .23, x - 270, size.height * .64,
              x + 90, size.height + 80);
        paint.color = amber.withValues(
            alpha: (dark ? .095 : .07) * (.5 + progress.value * .5));
        canvas.drawPath(path, paint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_SoundContours oldDelegate) =>
      oldDelegate.background != background ||
      oldDelegate.amber != amber ||
      oldDelegate.dark != dark ||
      oldDelegate.progress != progress;
}
