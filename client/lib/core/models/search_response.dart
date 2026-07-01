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
    // Backend wraps list results in a PaginatedResponse whose items live under
    // "data" (not "results"). Parse "data" so the fix is proven by an envelope that
    // only carries "results" failing to parse.
    return SearchResponse(
      results: (json['data'] as List<dynamic>)
          .map((e) => fromJsonT(e as Map<String, dynamic>))
          .toList(),
      total: (json['total'] as num?)?.toInt() ?? 0,
      limit: (json['limit'] as num?)?.toInt() ?? 0,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
    );
  }

  bool get hasMore => offset + results.length < total;
  int get nextOffset => offset + limit;
}
