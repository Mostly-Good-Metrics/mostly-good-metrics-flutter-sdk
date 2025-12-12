/// Official Flutter SDK for MostlyGoodMetrics.
///
/// Simple, privacy-focused analytics for your Flutter applications.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:mostly_good_metrics_flutter/mostly_good_metrics_flutter.dart';
///
/// // Initialize the SDK
/// await MostlyGoodMetrics.configure(
///   MGMConfiguration(
///     apiKey: 'your-api-key',
///     appVersion: '1.0.0',
///   ),
/// );
///
/// // Track events
/// MostlyGoodMetrics.track('button_clicked', properties: {'button_id': 'signup'});
///
/// // Identify users
/// MostlyGoodMetrics.identify('user-123');
/// ```
library mostly_good_metrics_flutter;

export 'src/mostly_good_metrics.dart' show MostlyGoodMetrics;
export 'src/types.dart'
    show
        MGMConfiguration,
        MGMEvent,
        MGMError,
        MGMErrorType,
        SendResult,
        EventsPayload,
        EventContext;
export 'src/storage.dart'
    show
        EventStorage,
        StateStorage,
        FileEventStorage,
        PreferencesStateStorage,
        InMemoryEventStorage,
        InMemoryStateStorage;
export 'src/network.dart'
    show NetworkClient, HttpNetworkClient, MockNetworkClient;
