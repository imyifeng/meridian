import 'api_client.dart';

/// One signed-in stretch of the app: the endpoint and the credential that
/// goes with it. The app builds it once the credential is proven — at boot
/// or by login — and every server-talking screen takes it as one value,
/// instead of threading an api-plus-token pair through each constructor.
class MeridianSession {
  final MeridianApi api;
  final String token;

  MeridianSession({required this.api, required this.token});
}
