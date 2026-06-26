import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_state.dart';
import '../../core/share/shared_url_parser.dart';
import '../../services/api_client.dart' as queue_api;

class ShareImportScreen extends StatefulWidget {
  final String sharedText;
  final bool autoSubmit;

  const ShareImportScreen({
    super.key,
    required this.sharedText,
    this.autoSubmit = false,
  });

  @override
  State<ShareImportScreen> createState() => _ShareImportScreenState();
}

class _ShareImportScreenState extends State<ShareImportScreen> {
  bool _isSubmitting = false;
  String? _error;
  bool _submitted = false;
  String? _downloadJobId;
  String? _autoSubmittedText;

  @override
  Widget build(BuildContext context) {
    final candidate = parseSharedUrlCandidate(widget.sharedText);
    final authState = context.watch<AuthState>();
    final theme = Theme.of(context);

    if (candidate != null &&
        widget.autoSubmit &&
        authState.isAuthenticated &&
        !_submitted &&
        !_isSubmitting &&
        _autoSubmittedText != widget.sharedText) {
      _autoSubmittedText = widget.sharedText;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_submitted && !_isSubmitting) {
          _submit(candidate);
        }
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Import shared link')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Shared to Open Music Player',
                  style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              if (candidate == null)
                _InvalidShareCard(sharedText: widget.sharedText)
              else
                _ShareCandidateCard(candidate: candidate),
              const SizedBox(height: 24),
              if (_error != null) ...[
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                const SizedBox(height: 12),
              ],
              if (_submitted) ...[
                FilledButton.icon(
                  onPressed: () => context.go('/library'),
                  icon: const Icon(Icons.library_music),
                  label: const Text('Open library'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => context.go('/downloads'),
                  icon: const Icon(Icons.download_done),
                  label: const Text('View downloads'),
                ),
                if (_downloadJobId != null) ...[
                  const SizedBox(height: 8),
                  Text('Download job: $_downloadJobId'),
                ],
                const SizedBox(height: 12),
              ],
              if (candidate != null && !_submitted)
                FilledButton.icon(
                  onPressed: _isSubmitting
                      ? null
                      : authState.isAuthenticated
                          ? () => _submit(candidate)
                          : () => context.go(
                                '/login?next=${Uri.encodeComponent(_shareRoute(autoSubmit: true))}',
                              ),
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(authState.isAuthenticated
                          ? Icons.library_add
                          : Icons.login),
                  label: Text(authState.isAuthenticated
                      ? 'Add to library'
                      : 'Sign in to import'),
                ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => context.go('/home'),
                child: const Text('Not now'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit(SharedUrlCandidate sharedUrl) async {
    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      final job = await context.read<queue_api.ApiClient>().createDownload(
            url: sharedUrl.url,
            sourceType: sharedUrl.downloadSourceType,
          );
      if (!mounted) return;
      setState(() {
        _submitted = true;
        _downloadJobId = job.jobId.isEmpty ? null : job.jobId;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Added to library downloads')),
      );
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _error = 'Could not reach the server. The request timed out.';
      });
    } on queue_api.ApiException catch (error) {
      if (!mounted) return;
      if (error.statusCode == 401) {
        await context.read<AuthState>().logout();
        if (!mounted) return;
        setState(() {
          _error = 'Session expired. Sign in again, then import the link.';
        });
      } else {
        setState(() {
          _error = 'Could not add this link to library: $error';
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not add this link to library: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  String _shareRoute({bool autoSubmit = false}) {
    final query = <String, String>{'text': widget.sharedText};
    if (autoSubmit) query['auto'] = '1';
    return Uri(path: '/share', queryParameters: query).toString();
  }
}

class _ShareCandidateCard extends StatelessWidget {
  final SharedUrlCandidate candidate;

  const _ShareCandidateCard({required this.candidate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(candidate.title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(candidate.url),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text(candidate.provider)),
                const Chip(label: Text('library download')),
                if (candidate.sourceId.isNotEmpty)
                  Chip(label: Text(candidate.sourceId)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InvalidShareCard extends StatelessWidget {
  final String sharedText;

  const _InvalidShareCard({required this.sharedText});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('No importable URL found', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(sharedText.isEmpty ? '(empty share)' : sharedText),
          ],
        ),
      ),
    );
  }
}
