import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../core/models/models.dart';

class AlbumTile extends StatelessWidget {
  final AlbumResult album;
  final VoidCallback onTap;

  const AlbumTile({
    super.key,
    required this.album,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 48,
          height: 48,
          child: album.coverUrl != null
              ? CachedNetworkImage(
                  imageUrl: album.coverUrl!,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => _buildPlaceholder(context),
                  errorWidget: (context, url, error) => _buildPlaceholder(context),
                )
              : _buildPlaceholder(context),
        ),
      ),
      title: Text(
        album.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          album.artist,
          if (album.releaseYear.isNotEmpty) album.releaseYear,
          album.typeDisplay,
        ].whereType<String>().join(' - '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: album.trackCount != null
          ? Text(
              '${album.trackCount} tracks',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            )
          : null,
      onTap: onTap,
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.album,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
