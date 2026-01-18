class SearchResponse<T> {
  final List<T> results;
  final int total;
  final int limit;
  final int offset;

  const SearchResponse({
    required this.results,
    required this.total,
    required this.limit,
    required this.offset,
  });

  factory SearchResponse.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromJsonT,
  ) {
    return SearchResponse(
      results: (json['results'] as List<dynamic>)
          .map((e) => fromJsonT(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int,
      limit: json['limit'] as int,
      offset: json['offset'] as int,
    );
  }

  bool get hasMore => offset + results.length < total;
  int get nextOffset => offset + limit;
}
