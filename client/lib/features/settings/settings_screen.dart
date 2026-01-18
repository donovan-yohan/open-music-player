import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models/settings_model.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/cache_provider.dart';
import '../../core/providers/settings_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: const [
          _AccountSection(),
          _PlaybackSection(),
          _StorageSection(),
          _AppearanceSection(),
          _AboutSection(),
        ],
      ),
    );
  }
}

/// Section header widget
class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}

/// Account section with email, logout, and delete account
class _AccountSection extends ConsumerWidget {
  const _AccountSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final user = authState.user;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Account'),
        if (user != null) ...[
          ListTile(
            leading: const Icon(Icons.email_outlined),
            title: const Text('Email'),
            subtitle: Text(user.email),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Log out'),
            onTap: () => _showLogoutDialog(context, ref),
          ),
        ] else
          ListTile(
            leading: const Icon(Icons.login),
            title: const Text('Log in'),
            subtitle: const Text('Sign in to your account'),
            onTap: () {
              // Navigate to login screen
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Login screen not yet implemented')),
              );
            },
          ),
        ListTile(
          leading: Icon(Icons.delete_forever, color: Theme.of(context).colorScheme.error),
          title: Text(
            'Delete account',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          subtitle: const Text('Permanently delete your account and data'),
          onTap: () => _showDeleteAccountDialog(context),
        ),
      ],
    );
  }

  void _showLogoutDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out'),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _showLogoutOptionsDialog(context, ref);
            },
            child: const Text('Log out'),
          ),
        ],
      ),
    );
  }

  void _showLogoutOptionsDialog(BuildContext context, WidgetRef ref) {
    bool clearCache = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Logout options'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                title: const Text('Clear cached data'),
                subtitle: const Text('Remove downloaded music and cached content'),
                value: clearCache,
                onChanged: (value) => setState(() => clearCache = value ?? false),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await ref.read(authProvider.notifier).logout(clearCache: clearCache);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Logged out successfully')),
                  );
                }
              },
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteAccountDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account'),
        content: const Text(
          'This feature is not yet available. Please contact support if you wish to delete your account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

/// Playback section with audio quality, gapless playback, and crossfade
class _PlaybackSection extends ConsumerWidget {
  const _PlaybackSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Playback'),
        ListTile(
          leading: const Icon(Icons.high_quality_outlined),
          title: const Text('Streaming quality'),
          subtitle: Text(settings.streamingQuality.displayName),
          trailing: const Text('(Always 320k)', style: TextStyle(fontSize: 12)),
          onTap: () => _showQualityPicker(
            context,
            'Streaming quality',
            settings.streamingQuality,
            settingsNotifier.setStreamingQuality,
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.playlist_play_outlined),
          title: const Text('Gapless playback'),
          subtitle: const Text('Remove silence between tracks'),
          value: settings.gaplessPlayback,
          onChanged: settingsNotifier.setGaplessPlayback,
        ),
        ListTile(
          leading: const Icon(Icons.swap_horiz_outlined),
          title: const Text('Crossfade'),
          subtitle: Text(
            settings.crossfadeDuration == 0
                ? 'Off'
                : '${settings.crossfadeDuration} seconds',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Text('0s'),
              Expanded(
                child: Slider(
                  value: settings.crossfadeDuration.toDouble(),
                  min: 0,
                  max: 12,
                  divisions: 12,
                  label: settings.crossfadeDuration == 0
                      ? 'Off'
                      : '${settings.crossfadeDuration}s',
                  onChanged: (value) => settingsNotifier.setCrossfadeDuration(value.toInt()),
                ),
              ),
              const Text('12s'),
            ],
          ),
        ),
      ],
    );
  }

  void _showQualityPicker(
    BuildContext context,
    String title,
    AudioQuality currentQuality,
    void Function(AudioQuality) onSelect,
  ) {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: AudioQuality.values.map((quality) {
          return RadioListTile<AudioQuality>(
            title: Text(quality.displayName),
            value: quality,
            groupValue: currentQuality,
            onChanged: (value) {
              if (value != null) {
                onSelect(value);
              }
              Navigator.pop(context);
            },
          );
        }).toList(),
      ),
    );
  }
}

/// Storage section with cache management and downloads
class _StorageSection extends ConsumerWidget {
  const _StorageSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);
    final cacheInfo = ref.watch(cacheProvider);
    final cacheNotifier = ref.read(cacheProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Storage'),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Cache size'),
          subtitle: Text(
            cacheInfo.isCalculating ? 'Calculating...' : cacheInfo.formattedSize,
          ),
          trailing: TextButton(
            onPressed: cacheInfo.isCalculating
                ? null
                : () => _showClearCacheDialog(context, cacheNotifier),
            child: const Text('Clear'),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('Downloads'),
          subtitle: const Text('Manage downloaded music'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Downloads screen not yet implemented')),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.high_quality_outlined),
          title: const Text('Download quality'),
          subtitle: Text(settings.downloadQuality.displayName),
          onTap: () => _showQualityPicker(
            context,
            'Download quality',
            settings.downloadQuality,
            settingsNotifier.setDownloadQuality,
          ),
        ),
      ],
    );
  }

  void _showClearCacheDialog(BuildContext context, CacheNotifier notifier) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear cache'),
        content: const Text(
          'This will remove all cached data including album artwork and temporary files. Downloaded music will not be affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              notifier.clearCache();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Cache cleared')),
              );
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _showQualityPicker(
    BuildContext context,
    String title,
    AudioQuality currentQuality,
    void Function(AudioQuality) onSelect,
  ) {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: AudioQuality.values.map((quality) {
          return RadioListTile<AudioQuality>(
            title: Text(quality.displayName),
            value: quality,
            groupValue: currentQuality,
            onChanged: (value) {
              if (value != null) {
                onSelect(value);
              }
              Navigator.pop(context);
            },
          );
        }).toList(),
      ),
    );
  }
}

/// Appearance section with theme selection
class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Appearance'),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Theme'),
          subtitle: Text(settings.themeMode.displayName),
          onTap: () => _showThemePicker(context, settings.themeMode, settingsNotifier),
        ),
      ],
    );
  }

  void _showThemePicker(
    BuildContext context,
    AppThemeMode currentMode,
    SettingsNotifier notifier,
  ) {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Theme'),
        children: AppThemeMode.values.map((mode) {
          return RadioListTile<AppThemeMode>(
            title: Text(mode.displayName),
            value: mode,
            groupValue: currentMode,
            onChanged: (value) {
              if (value != null) {
                notifier.setThemeMode(value);
              }
              Navigator.pop(context);
            },
          );
        }).toList(),
      ),
    );
  }
}

/// About section with app info and legal links
class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('About'),
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snapshot) {
            final version = snapshot.data?.version ?? '...';
            final buildNumber = snapshot.data?.buildNumber ?? '';
            return ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Version'),
              subtitle: Text('$version${buildNumber.isNotEmpty ? ' ($buildNumber)' : ''}'),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.code_outlined),
          title: const Text('Open source licenses'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Open Music Player',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.privacy_tip_outlined),
          title: const Text('Privacy policy'),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _launchUrl('https://openmusicplayer.app/privacy'),
        ),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: const Text('Terms of service'),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _launchUrl('https://openmusicplayer.app/terms'),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
