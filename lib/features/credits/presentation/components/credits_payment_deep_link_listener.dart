import 'dart:async';

import 'package:zedu/core/core.dart';
import 'package:zedu/features/features.dart';

class CreditsPaymentDeepLinkListener extends ConsumerStatefulWidget {
  const CreditsPaymentDeepLinkListener({
    super.key,
    required this.child,
    this.appLinks,
  });

  final Widget child;
  final AppLinks? appLinks;

  @override
  ConsumerState<CreditsPaymentDeepLinkListener> createState() =>
      _CreditsPaymentDeepLinkListenerState();
}

class _CreditsPaymentDeepLinkListenerState
    extends ConsumerState<CreditsPaymentDeepLinkListener> {
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  /// Set only once `verifyPayment` has actually run for this session.
  String? _processedSessionId;

  /// A payment session that arrived before the organisation was loaded.
  String? _pendingSessionId;

  /// Stops two deliveries of the same link racing into `verifyPayment`.
  bool _verifying = false;

  static const _tag = 'CreditsPaymentDeepLinkListener';

  @override
  void initState() {
    super.initState();
    _appLinks = widget.appLinks ?? AppLinks();
    _initDeepLinks();
  }

  Future<void> _initDeepLinks() async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        await _handleUri(initialUri);
      }
    } catch (error) {
      AppLogger.w('Failed to read initial payment deep link', tag: _tag);
    }

    _linkSubscription = _appLinks.uriLinkStream.listen(
      (uri) => unawaited(_handleUri(uri)),
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.w('Payment deep link stream error: $error', tag: _tag);
      },
    );
  }

  Future<void> _handleUri(Uri uri) async {
    final sessionId = CreditsPaymentDeepLinkParser.extractSessionId(uri);
    if (sessionId == null) return;
    if (sessionId == _processedSessionId || sessionId == _pendingSessionId) {
      return;
    }

    final orgId = ref.read(authNotifierProvider).user?.currentOrg;
    if (orgId == null || orgId.isEmpty) {
      // Cold start: this link launched the app, so auth has not resolved yet.
      // Remember it rather than marking it processed and losing the payment.
      _pendingSessionId = sessionId;
      AppLogger.i(
        'Deferring credit payment session until auth resolves',
        tag: _tag,
      );
      return;
    }

    await _verifySession(sessionId: sessionId, orgId: orgId);
  }

  /// Picks up a deferred session as soon as the organisation exists.
  void _drainPendingSession() {
    final sessionId = _pendingSessionId;
    if (sessionId == null) return;

    final orgId = ref.read(authNotifierProvider).user?.currentOrg;
    if (orgId == null || orgId.isEmpty) return;

    _pendingSessionId = null;
    unawaited(_verifySession(sessionId: sessionId, orgId: orgId));
  }

  Future<void> _verifySession({
    required String sessionId,
    required String orgId,
  }) async {
    if (_verifying || sessionId == _processedSessionId) return;
    _verifying = true;
    try {
      AppLogger.i('Verifying credit payment session', tag: _tag);
      final verified = await ref
          .read(creditsNotifierProvider.notifier)
          .verifyPayment(sessionId: sessionId, orgId: orgId);
      _processedSessionId = sessionId;

      if (!mounted) return;

      if (verified) {
        AppToastService.show(
          context,
          type: AppToastType.success,
          message: 'AI credits purchased successfully!',
        );
        if (GoRouterState.of(context).uri.path != AppRouter.buyCredits) {
          context.go(AppRouter.buyCredits);
        }
        return;
      }

      final error = ref.read(creditsNotifierProvider).error;
      if (error != null) {
        AppToastService.show(context, type: AppToastType.error, message: error);
      }
    } finally {
      _verifying = false;
    }
  }

  @override
  void dispose() {
    unawaited(_linkSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Auth resolving is what unblocks a deferred cold-start payment link.
    ref.listen(authNotifierProvider, (_, __) => _drainPendingSession());
    return widget.child;
  }
}
