/// Immutable compile-time endpoint shared by transport, Settings and token stores.
class ApiEndpoint {
  static final String baseUrl = validate(const String.fromEnvironment(
    'OMP_API_BASE_URL',
    defaultValue: 'http://localhost:8080/api/v1',
  ));

  static String validate(String value) {
    // Reject literal controls before Uri can normalize them into encoded paths.
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('Invalid OMP_API_BASE_URL');
    }
    final rawPath = value.replaceFirst(RegExp(r'^[a-z]+://[^/]+'), '');
    final uri = Uri.tryParse(value);
    if (value.isEmpty ||
        RegExp(r'[\s\\?#]').hasMatch(value) ||
        !RegExp(r'^https?://').hasMatch(value) ||
        uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.host.contains('*') ||
        RegExp(r'[@]|:$').hasMatch(value.split('/')[2]) ||
        uri.port < 1 ||
        uri.port > 65535 ||
        !RegExp(r'/api/v1/?$').hasMatch(rawPath) ||
        rawPath.contains('//') ||
        RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(rawPath) ||
        RegExp(r'%(2f|5c|2e|0[0-9a-f]|1[0-9a-f]|7f)', caseSensitive: false)
            .hasMatch(rawPath) ||
        rawPath.split('/').any((part) => part == '.' || part == '..')) {
      throw const FormatException('Invalid OMP_API_BASE_URL');
    }
    return value.replaceFirst(RegExp(r'/$'), '');
  }
}
