# MostlyGoodMetrics Flutter SDK

A lightweight Flutter SDK for tracking analytics events with [MostlyGoodMetrics](https://mostlygoodmetrics.com).

## Requirements

- Flutter 3.10+
- Dart 3.0+

## Platform Support

| Platform | Supported |
|----------|-----------|
| iOS      | Yes       |
| Android  | Yes       |
| Web      | Yes       |
| macOS    | Yes       |
| Windows  | Yes       |
| Linux    | Yes       |

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  mostly_good_metrics_flutter: ^0.1.0
```

Then run:

```bash
flutter pub get
```

## Quick Start

### 1. Initialize the SDK

Initialize once at app startup (typically in `main.dart`):

```dart
import 'package:flutter/material.dart';
import 'package:mostly_good_metrics_flutter/mostly_good_metrics_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await MostlyGoodMetrics.configure(
    MGMConfiguration(apiKey: 'mgm_proj_your_api_key'),
  );

  runApp(MyApp());
}
```

### 2. Track Events

```dart
// Simple event
MostlyGoodMetrics.track('button_clicked');

// Event with properties
MostlyGoodMetrics.track('purchase_completed', properties: {
  'product_id': 'SKU123',
  'price': 29.99,
  'currency': 'USD',
});
```

### 3. Identify Users

```dart
// Set user identity
await MostlyGoodMetrics.identify('user_123');

// Reset identity (e.g., on logout)
await MostlyGoodMetrics.resetIdentity();
```

That's it! Events are automatically batched and sent.

## Configuration Options

For more control, pass additional configuration:

```dart
await MostlyGoodMetrics.configure(
  MGMConfiguration(
    apiKey: 'mgm_proj_your_api_key',
    baseUrl: 'https://ingest.mostlygoodmetrics.com',
    environment: 'production',
    appVersion: '1.0.0', // Required for install/update tracking
    maxBatchSize: 100,
    flushInterval: 30,
    maxStoredEvents: 10000,
    enableDebugLogging: kDebugMode,
    trackAppLifecycleEvents: true,
  ),
);
```

| Option | Default | Description |
|--------|---------|-------------|
| `apiKey` | Required | Your MostlyGoodMetrics API key |
| `baseUrl` | `https://ingest.mostlygoodmetrics.com` | API endpoint |
| `environment` | `"production"` | Environment name |
| `appVersion` | Required | App version string for install/update tracking |
| `maxBatchSize` | `100` | Events per batch (1-1000) |
| `flushInterval` | `30` | Auto-flush interval in seconds |
| `maxStoredEvents` | `10000` | Max cached events |
| `enableDebugLogging` | `false` | Enable debug output |
| `trackAppLifecycleEvents` | `true` | Auto-track lifecycle events |

## Automatic Events

When `trackAppLifecycleEvents` is enabled (default), the SDK automatically tracks:

| Event | When | Properties |
|-------|------|------------|
| `$app_installed` | First launch after install | - |
| `$app_updated` | First launch after version change | `previous_version`, `current_version` |
| `$app_opened` | App started | - |
| `$app_foregrounded` | App became active | - |
| `$app_backgrounded` | App went to background | - |

## Automatic Context

The SDK automatically includes the following context with every event:

| Property | Description | Example |
|----------|-------------|---------|
| `platform` | Current platform | `ios`, `android`, `web`, `macos`, `windows`, `linux` |
| `app_version` | App version from config | `1.0.0` |
| `os_version` | Operating system version | `17.0.1` |
| `environment` | Environment from config | `production` |
| `device_manufacturer` | Device manufacturer | `Apple` (iOS/macOS only) |
| `locale` | User's locale | `en_US` |
| `timezone` | User's timezone | `EST`, `UTC+5` |
| `user_id` | Identified or anonymous user ID | `user_123` or `$anon_abc123` |
| `session_id` | Current session ID | `550e8400-e29b-41d4-a716-446655440000` |

## Event Naming

Event names must:
- Start with a letter (or `$` for system events)
- Contain only alphanumeric characters, underscores, and spaces
- Be 255 characters or less

```dart
// Valid
MostlyGoodMetrics.track('button_clicked');
MostlyGoodMetrics.track('PurchaseCompleted');
MostlyGoodMetrics.track('step_1_completed');
MostlyGoodMetrics.track('Button Clicked');  // spaces allowed

// Invalid (will throw MGMError)
MostlyGoodMetrics.track('123_event');       // starts with number
MostlyGoodMetrics.track('event-name');      // contains hyphen
MostlyGoodMetrics.track('_private_event');  // starts with underscore
```

## Properties

Events support various property types:

```dart
MostlyGoodMetrics.track('checkout', properties: {
  'string_prop': 'value',
  'int_prop': 42,
  'double_prop': 3.14,
  'bool_prop': true,
  'list_prop': ['a', 'b', 'c'],
  'nested': {
    'key': 'value',
  },
});
```

**Limits:**
- Nesting depth: max 3 levels

## Manual Flush

Events are automatically flushed periodically and when the app backgrounds. You can also trigger a manual flush:

```dart
await MostlyGoodMetrics.flush();
```

To check pending events:

```dart
final count = await MostlyGoodMetrics.getPendingEventCount();
print('$count events pending');
```

To clear pending events:

```dart
await MostlyGoodMetrics.clearPendingEvents();
```

## Session Management

The SDK automatically generates a new session ID when:
- The SDK is configured
- `resetIdentity()` is called
- `startNewSession()` is called

```dart
// Start a new session manually
await MostlyGoodMetrics.startNewSession();

// Access current session ID
final sessionId = MostlyGoodMetrics.sessionId;
```

## Automatic Behavior

The SDK automatically:

- **Persists** events to local storage, surviving app restarts
- **Batches** events for efficient network usage
- **Flushes** events on interval (default: every 30 seconds)
- **Flushes** events when the app goes to background
- **Retries** failed requests, preserving events for later delivery
- **Persists** user identity across app launches
- **Generates** unique session IDs per app launch
- **Handles** rate limiting gracefully

## Error Handling

The SDK throws `MGMError` for validation errors:

```dart
try {
  MostlyGoodMetrics.track('invalid-event-name');
} on MGMError catch (e) {
  print('Error type: ${e.type}');
  print('Message: ${e.message}');
}
```

Error types:
- `MGMErrorType.notConfigured` - SDK not configured
- `MGMErrorType.invalidEventName` - Invalid event name
- `MGMErrorType.invalidProperties` - Invalid properties (too deeply nested)
- `MGMErrorType.networkError` - Network failure
- `MGMErrorType.storageError` - Storage failure
- `MGMErrorType.rateLimited` - API rate limited

## Debug Logging

Enable debug logging to see SDK activity:

```dart
await MostlyGoodMetrics.configure(
  MGMConfiguration(
    apiKey: 'mgm_proj_your_api_key',
    enableDebugLogging: true,
  ),
);
```

Output example:
```
[MostlyGoodMetrics] Configuring MostlyGoodMetrics SDK
[MostlyGoodMetrics] Tracked event: button_clicked
[MostlyGoodMetrics] Flushing 5 events
[MostlyGoodMetrics] Successfully sent 5 events
```

## Running the Example

```bash
cd example
flutter pub get
flutter run
```

## Testing

To run the tests:

```bash
flutter test
```

## License

MIT
