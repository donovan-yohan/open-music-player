class AuthTokens {
  final String accessToken;
  final String refreshToken;

  const AuthTokens({required this.accessToken, required this.refreshToken});
}

AuthTokens parseAuthTokens(dynamic payload) {
  if (payload is! Map) {
    throw const FormatException('Auth response must be a JSON object');
  }

  final accessToken = payload['accessToken'] ?? payload['access_token'];
  final refreshToken = payload['refreshToken'] ?? payload['refresh_token'];

  if (accessToken is! String || refreshToken is! String) {
    throw const FormatException('Auth response is missing token fields');
  }

  return AuthTokens(accessToken: accessToken, refreshToken: refreshToken);
}

Map<String, String> refreshTokenPayload(String token) {
  return {'refreshToken': token};
}
