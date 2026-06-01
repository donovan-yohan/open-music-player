class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    'OMP_API_BASE_URL',
    defaultValue: 'http://localhost:8080/api/v1',
  );
}
