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
  /// The app carries it across restarts via the identity store; null only
  /// when no identity is known for the credential (e.g. a pre-upgrade
  /// install resuming a token it never recorded an owner for).
  final User? user;

  MeridianSession({required this.api, required this.token, this.user});
}
