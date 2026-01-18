import 'album.dart';

class ArtistResult {
  final String mbid;
  final String name;
  final String? sortName;
  final String? type;
  final String? country;
  final String? disambiguation;
  final int? score;

  const ArtistResult({
    required this.mbid,
    required this.name,
    this.sortName,
    this.type,
    this.country,
    this.disambiguation,
    this.score,
  });

  factory ArtistResult.fromJson(Map<String, dynamic> json) {
    return ArtistResult(
      mbid: json['mbid'] as String,
      name: json['name'] as String,
      sortName: json['sortName'] as String?,
      type: json['type'] as String?,
      country: json['country'] as String?,
      disambiguation: json['disambiguation'] as String?,
      score: json['score'] as int?,
    );
  }
}

class ArtistDetail {
  final String id;
  final String name;
  final String? sortName;
  final String? type;
  final String? country;
  final String? disambiguation;
  final String? beginDate;
  final String? endDate;
  final List<ReleaseInfo> releases;

  const ArtistDetail({
    required this.id,
    required this.name,
    this.sortName,
    this.type,
    this.country,
    this.disambiguation,
    this.beginDate,
    this.endDate,
    this.releases = const [],
  });

  factory ArtistDetail.fromJson(Map<String, dynamic> json) {
    return ArtistDetail(
      id: json['id'] as String,
      name: json['name'] as String,
      sortName: json['sortName'] as String?,
      type: json['type'] as String?,
      country: json['country'] as String?,
      disambiguation: json['disambiguation'] as String?,
      beginDate: json['beginDate'] as String?,
      endDate: json['endDate'] as String?,
      releases: (json['releases'] as List<dynamic>?)
              ?.map((e) => ReleaseInfo.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  String get typeDisplay {
    if (type == null) return '';
    switch (type) {
      case 'person':
        return 'Solo Artist';
      case 'group':
        return 'Band';
      case 'orchestra':
        return 'Orchestra';
      case 'choir':
        return 'Choir';
      case 'character':
        return 'Character';
      default:
        return type!;
    }
  }

  String? get activeYears {
    if (beginDate == null) return null;
    final startYear = beginDate!.split('-').first;
    if (endDate != null) {
      final endYear = endDate!.split('-').first;
      return '$startYear - $endYear';
    }
    return '$startYear - present';
  }
}
