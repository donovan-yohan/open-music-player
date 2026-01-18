import 'track.dart';

class AlbumResult {
  final String mbid;
  final String title;
  final String? artist;
  final String? artistMbid;
  final String? releaseDate;
  final String? primaryType;
  final List<String>? secondaryTypes;
  final int? trackCount;
  final int? score;

  const AlbumResult({
    required this.mbid,
    required this.title,
    this.artist,
    this.artistMbid,
    this.releaseDate,
    this.primaryType,
    this.secondaryTypes,
    this.trackCount,
    this.score,
  });

  factory AlbumResult.fromJson(Map<String, dynamic> json) {
    return AlbumResult(
      mbid: json['mbid'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String?,
      artistMbid: json['artistMbid'] as String?,
      releaseDate: json['releaseDate'] as String?,
      primaryType: json['primaryType'] as String?,
      secondaryTypes: (json['secondaryTypes'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      trackCount: json['trackCount'] as int?,
      score: json['score'] as int?,
    );
  }

  String get releaseYear {
    if (releaseDate == null || releaseDate!.isEmpty) return '';
    return releaseDate!.split('-').first;
  }

  String get typeDisplay {
    if (primaryType == null) return 'Album';
    switch (primaryType) {
      case 'album':
        return 'Album';
      case 'single':
        return 'Single';
      case 'ep':
        return 'EP';
      case 'broadcast':
        return 'Broadcast';
      default:
        return primaryType!;
    }
  }
}

class AlbumDetail {
  final String id;
  final String title;
  final String? artist;
  final String? artistId;
  final String? date;
  final String? country;
  final int? trackCount;
  final String? coverArtUrl;
  final List<TrackDetail> tracks;

  const AlbumDetail({
    required this.id,
    required this.title,
    this.artist,
    this.artistId,
    this.date,
    this.country,
    this.trackCount,
    this.coverArtUrl,
    this.tracks = const [],
  });

  factory AlbumDetail.fromJson(Map<String, dynamic> json) {
    return AlbumDetail(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String?,
      artistId: json['artistId'] as String?,
      date: json['date'] as String?,
      country: json['country'] as String?,
      trackCount: json['trackCount'] as int?,
      coverArtUrl: json['coverArtUrl'] as String?,
      tracks: (json['tracks'] as List<dynamic>?)
              ?.map((e) => TrackDetail.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  String get releaseYear {
    if (date == null || date!.isEmpty) return '';
    return date!.split('-').first;
  }
}

class ReleaseInfo {
  final String id;
  final String title;
  final String? date;
  final String? coverArtUrl;

  const ReleaseInfo({
    required this.id,
    required this.title,
    this.date,
    this.coverArtUrl,
  });

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) {
    return ReleaseInfo(
      id: json['id'] as String,
      title: json['title'] as String,
      date: json['date'] as String?,
      coverArtUrl: json['coverArtUrl'] as String?,
    );
  }

  String get releaseYear {
    if (date == null || date!.isEmpty) return '';
    return date!.split('-').first;
  }
}
