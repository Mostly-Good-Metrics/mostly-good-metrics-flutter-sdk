# MostlyGoodMetrics Flutter SDK

A lightweight Flutter SDK for tracking analytics events with [MostlyGoodMetrics](https://mostlygoodmetrics.com).

## Requirements

- Flutter 3.10+
- Dart 3.0+

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
    baseUrl: 'https://mostlygoodmetrics.com',
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
| `baseUrl` | `https://mostlygoodmetrics.com` | API endpoint |
| `environment` | `"production"` | Environment name |
| `appVersion` | - | App version string (required for install/update tracking) |
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
| `$app_opened` | App became active (foreground) | - |
| `$app_backgrounded` | App went to background | - |

## Automatic Context/Properties

Every event automatically includes:

| Field | Example | Description |
|-------|---------|-------------|
| `platform` | `"ios"` | Platform (ios, android, web, macos, windows, linux) |
| `os_version` | `"17.1"` | Operating system version |
| `app_version` | `"1.0.0"` | App version (if configured) |
| `environment` | `"production"` | Environment from configuration |
| `session_id` | `"uuid..."` | Unique session ID (per app launch) |
| `user_id` | `"user_123"` | User ID (if set via `identify()`) |
| `device_manufacturer` | `"Apple"` | Device manufacturer (iOS/macOS only) |
| `locale` | `"en_US"` | User's locale |
| `timezone` | `"EST"` | User's timezone |

> **Note:** The `$` prefix indicates reserved system events and properties. Avoid using `$` prefix for your own custom events.

## Event Naming

Event names must:
- Start with a letter (or `$` for system events)
- Contain only alphanumeric characters and underscores
- Be 255 characters or less

```dart
// Valid
MostlyGoodMetrics.track('button_clicked');
MostlyGoodMetrics.track('PurchaseCompleted');
MostlyGoodMetrics.track('step_1_completed');

// Invalid (will throw MGMError)
MostlyGoodMetrics.track('123_event');       // starts with number
MostlyGoodMetrics.track('event-name');      // contains hyphen
MostlyGoodMetrics.track('button clicked');  // contains space
```

## Properties

Events support various property types:

```dart
MostlyGoodMetrics.track('checkout', properties: {
  'string_prop': 'value',
  'int_prop': 42,
  'double_prop': 3.14,
  'bool_prop': true,
  'null_prop': null,  // null values are included in the event
  'list_prop': ['a', 'b', 'c'],
  'nested': {
    'key': 'value',
  },
});
```

**Limits:**
- String values: truncated to 1000 characters
- Nesting depth: max 3 levels

## User Identification

The SDK provides methods for identifying users and managing their identity:

```dart
// Set user identity
await MostlyGoodMetrics.identify('user_123');

// Reset identity (e.g., on logout)
await MostlyGoodMetrics.resetIdentity();
```

When you call `identify()`:
- The user ID is stored and persisted across app launches
- All subsequent events include this user ID

When you call `resetIdentity()`:
- The stored user ID is cleared
- A new session is started
- Use this when users log out to ensure clean session separation

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

## Automatic Behavior

The SDK automatically:

- **Persists events** to local storage, surviving app restarts
- **Batches events** for efficient network usage
- **Flushes on interval** (default: every 30 seconds)
- **Flushes on background** when the app goes to background
- **Retries on failure** for network errors (events are preserved)
- **Persists user ID** across app launches
- **Generates session IDs** per app launch

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

## Platform Support

| Platform | Supported |
|----------|-----------|
| iOS      | Yes       |
| Android  | Yes       |
| Web      | Yes       |
| macOS    | Yes       |
| Windows  | Yes       |
| Linux    | Yes       |

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
