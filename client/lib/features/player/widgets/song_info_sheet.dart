import 'package:flutter/material.dart';

import '../../../models/track_analysis.dart';

/// A single labelled fact shown in the song-info sheet (e.g. "Tempo" / "128 BPM").
class SongInfoRow {
  final String label;
  final String value;

  const SongInfoRow({required this.label, required this.value});
}

/// Pure view-model for the read-only song-info sheet.
///
/// Derived from a [TrackAnalysis] (or its absence). When [rows] is empty the
/// analysis is unavailable/pending/failed and [unavailableMessage] explains why.
class SongInfoDisplay {
  final List<SongInfoRow> rows;
  final String? unavailableMessage;

  const SongInfoDisplay({required this.rows, this.unavailableMessage});

  bool get hasData => rows.isNotEmpty;
}

/// Builds the display model for the song-info sheet from an [analysis].
///
/// Only the "listener facing" fields are surfaced — BPM (tempo), musical key +
/// camelot, and energy. Waveform / sections / cue candidates are intentionally
/// omitted (this is read-only song info, not a DJ editor).
///
/// A null [analysis] (or one thrown away by the caller because the endpoint
/// 404'd or the analyzer is disabled) retains any immutable source-quality row
/// and carries a clear unavailable message, so missing analysis never hides
/// artifact facts or crashes the UI.
SongInfoDisplay buildSongInfoDisplay(
  TrackAnalysis? analysis, {
  String? sourceQuality,
}) {
  final rows = <SongInfoRow>[
    if (sourceQuality != null && sourceQuality.trim().isNotEmpty)
      SongInfoRow(label: 'Source', value: sourceQuality.trim()),
  ];

  if (analysis == null) {
    return SongInfoDisplay(
      rows: rows,
      unavailableMessage: 'Analysis unavailable for this track.',
    );
  }

  final summary = analysis.summary;

  final bpm = summary?.bpm?.numericValue;
  if (bpm != null) {
    rows.add(SongInfoRow(label: 'Tempo', value: '${bpm.round()} BPM'));
  }

  final key = summary?.key?.textValue;
  final camelot = summary?.camelot?.textValue;
  final keyValue = _formatKey(key, camelot);
  if (keyValue != null) {
    rows.add(SongInfoRow(label: 'Key', value: keyValue));
  }

  final energy = summary?.energy?.numericValue;
  if (energy != null) {
    rows.add(
      SongInfoRow(
        label: 'Energy',
        value: '${(energy.clamp(0, 1) * 100).round()}%',
      ),
    );
  }

  final integratedLufs = summary?.loudness?.integratedLufs;
  if (integratedLufs != null) {
    rows.add(
      SongInfoRow(
        label: 'Loudness',
        value: '${integratedLufs.toStringAsFixed(1)} LUFS',
      ),
    );
  }

  final hasAnalysisRows = bpm != null ||
      keyValue != null ||
      energy != null ||
      integratedLufs != null;
  if (hasAnalysisRows) {
    return SongInfoDisplay(rows: rows);
  }

  return SongInfoDisplay(
    rows: rows,
    unavailableMessage: _messageForStatus(analysis.status),
  );
}

String? _formatKey(String? key, String? camelot) {
  if (key != null && camelot != null) return '$key ($camelot)';
  if (key != null) return key;
  if (camelot != null) return camelot;
  return null;
}

String _messageForStatus(TrackAnalysisStatus status) {
  switch (status) {
    case TrackAnalysisStatus.pending:
    case TrackAnalysisStatus.analyzing:
      return 'Analysis in progress. Check back soon.';
    case TrackAnalysisStatus.failed:
      return 'Analysis failed for this track.';
    case TrackAnalysisStatus.stale:
      return 'Analysis is being refreshed for this track.';
    case TrackAnalysisStatus.unsupported:
      return 'Analysis is not supported for this track.';
    case TrackAnalysisStatus.analyzed:
    case TrackAnalysisStatus.unknown:
      return 'Analysis unavailable for this track.';
  }
}

/// Read-only bottom sheet that shows a track's audio analysis (tempo, key,
/// energy). Fetches lazily via [analysisLoader]; any failure (disabled analyzer,
/// missing analysis, network error) collapses into a friendly "Analysis
/// unavailable" state rather than an error.
class SongInfoSheet extends StatefulWidget {
  const SongInfoSheet({
    super.key,
    required this.title,
    required this.artist,
    required this.analysisLoader,
    this.sourceQuality,
  });

  final String title;
  final String? artist;
  final String? sourceQuality;

  /// Lazily loads the analysis. Implementations typically delegate to
  /// `AnalysisService.getTrackAnalysis`. May throw; the sheet catches it.
  final Future<TrackAnalysis> Function() analysisLoader;

  @override
  State<SongInfoSheet> createState() => _SongInfoSheetState();
}

class _SongInfoSheetState extends State<SongInfoSheet> {
  late Future<SongInfoDisplay> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<SongInfoDisplay> _load() async {
    try {
      final analysis = await widget.analysisLoader();
      return buildSongInfoDisplay(
        analysis,
        sourceQuality: widget.sourceQuality,
      );
    } catch (_) {
      // 404 (no analysis), 503 (analyzer disabled), or any transport error all
      // resolve to the same read-only "unavailable" state — never crash.
      return buildSongInfoDisplay(null, sourceQuality: widget.sourceQuality);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.title,
                key: const ValueKey('song_info_sheet_title'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: colors.onSurface,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                widget.artist ?? 'Unknown Artist',
                style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 20),
              FutureBuilder<SongInfoDisplay>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  final display = snapshot.data ??
                      buildSongInfoDisplay(
                        null,
                        sourceQuality: widget.sourceQuality,
                      );
                  if (!display.hasData) {
                    return _buildUnavailable(display.unavailableMessage);
                  }
                  return Column(
                    children: [
                      for (final row in display.rows) _buildRow(context, row),
                      if (display.unavailableMessage != null)
                        _buildUnavailable(display.unavailableMessage),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, SongInfoRow row) {
    final colors = Theme.of(context).colorScheme;
    final label = Text(
      row.label,
      style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
    );
    final value = Text(
      row.value,
      key: row.label == 'Source'
          ? const ValueKey('song_info_source_quality')
          : null,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: colors.onSurface,
      ),
      textAlign: TextAlign.end,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaledFontSize = MediaQuery.textScalerOf(context).scale(14);
        final stackFacts = constraints.maxWidth < 360 || scaledFontSize >= 28;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: stackFacts
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    label,
                    const SizedBox(height: 4),
                    Align(alignment: Alignment.centerLeft, child: value),
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    label,
                    const SizedBox(width: 16),
                    Flexible(child: value),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildUnavailable(String? message) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Icon(Icons.analytics_outlined, color: color, size: 32),
          const SizedBox(height: 12),
          Text(
            message ?? 'Analysis unavailable for this track.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: color),
          ),
        ],
      ),
    );
  }
}
