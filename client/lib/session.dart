import 'api_client.dart';

/// One signed-in stretch of the app: the endpoint, the credential that
/// goes with it, and — when the sign-in produced it — the signed-in user.
/// The app builds it once the credential is proven — at boot or by login —
/// and every server-talking screen takes it as one value, instead of
/// threading an api-plus-token pair through each constructor.
class MeridianSession {
  final MeridianApi api;
  final String token;

  /// The user the token belongs to, as the server reported it at sign-in.
  /// Null when the app resumed from a stored credential alone.
  final User? user;

  MeridianSession({required this.api, required this.token, this.user});
}
