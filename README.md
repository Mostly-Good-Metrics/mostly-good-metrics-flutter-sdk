# MostlyGoodMetrics Flutter SDK

A lightweight Flutter SDK for tracking analytics events with [MostlyGoodMetrics](https://mostlygoodmetrics.com).

## Table of Contents

- [Requirements](#requirements)
- [Platform Support](#platform-support)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Configuration Options](#configuration-options)
- [Automatic Behavior](#automatic-behavior)
- [Automatic Events](#automatic-events)
- [Automatic Context](#automatic-context)
- [Event Naming](#event-naming)
- [Properties](#properties)
- [Manual Flush](#manual-flush)
- [Session Management](#session-management)
- [Debug Logging](#debug-logging)
- [Error Handling](#error-handling)
- [Framework Integration](#framework-integration)
- [Running the Example](#running-the-example)
- [Testing](#testing)
- [License](#license)

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

Then install dependencies:

```bash
flutter pub get
```

Or install directly via command line:

```bash
flutter pub add mostly_good_metrics_flutter
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

  runApp(const MyApp());
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

## Automatic Behavior

The SDK automatically handles common tasks so you can focus on tracking what matters:

- **Anonymous user ID generation** - UUID automatically generated and persisted for anonymous tracking
- **User ID persistence** - Identity set via `identify()` persists across app launches; falls back to anonymous ID when reset
- **Event persistence** - Events are saved to local storage and survive app restarts
- **Batch processing** - Events are grouped for efficient network usage
- **Periodic flush** - Events are sent every 30 seconds (configurable via `flushInterval`)
- **Background flush** - Events are sent when the app goes to background
- **Retry on failure** - Failed requests are retried; events are preserved until successfully sent
- **Session management** - New session ID generated on each app launch
- **Deduplication** - Events include unique IDs (`client_event_id`) to prevent duplicate processing

## Automatic Events

When `trackAppLifecycleEvents` is enabled (default), the SDK automatically tracks:

| Event | When | Properties |
|-------|------|------------|
| `$app_installed` | First launch after install | - |
| `$app_updated` | First launch after version change | `previous_version`, `current_version` |
| `$app_opened` | App became active | - |
| `$app_backgrounded` | App went to background | - |

## Automatic Context

Every event automatically includes contextual information. You don't need to manually add these fields.

| Field | Example | Description |
|-------|---------|-------------|
| `client_event_id` | `550e8400-e29b-41d4-a716-446655440000` | Unique UUID for deduplication |
| `timestamp` | `2024-01-15T10:30:00.000Z` | ISO 8601 event time |
| `user_id` | `user_123` or `$anon_abc123def456` | Identified user ID (if set via `identify()`), or anonymous ID |
| `session_id` | `a1b2c3d4-e5f6-7890-abcd-ef1234567890` | UUID per app launch (new session each launch) |
| `platform` | `ios`, `android`, `web`, `macos`, `windows`, `linux` | Platform identifier |
| `environment` | `production` | Environment name (from config) |
| `locale` | `en_US`, `fr_FR` | User's locale from device settings |
| `timezone` | `EST`, `PST`, `UTC+5` | User's timezone offset name |
| `os_version` | `iOS 17.4`, `Android 14`, `macOS 14.3`, `Version 10.0 (Build 19045)` | Operating system version string |
| `app_version` | `1.2.3` | App version (if configured) |
| `device_manufacturer` | `Apple` | Device manufacturer (iOS/macOS only; `null` on other platforms) |

> **Note:** This context is included automatically—no additional code required.

## Event Naming

Event names must:
- Start with a letter (or `$` for system events)
- Contain only alphanumeric characters, underscores, and spaces
- Be 255 characters or less

**Reserved `$` prefix:** The `$` prefix is reserved for system events (like `$app_opened`, `$app_installed`). Do not use `$` for custom event names.

```dart
// Valid
MostlyGoodMetrics.track('button_clicked');
MostlyGoodMetrics.track('PurchaseCompleted');
MostlyGoodMetrics.track('step_1_completed');
MostlyGoodMetrics.track('user signed up');  // spaces allowed

// Invalid (will throw MGMError)
MostlyGoodMetrics.track('123_event');      // starts with number
MostlyGoodMetrics.track('event-name');     // contains hyphen
MostlyGoodMetrics.track('$custom_event');  // $ prefix is reserved
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
- String values: max 1000 characters
- Nesting depth: max 3 levels
- Total event payload: max 10KB

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

## Framework Integration

### MaterialApp

For a complete Flutter app setup with MostlyGoodMetrics:

```dart
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:mostly_good_metrics_flutter/mostly_good_metrics_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await MostlyGoodMetrics.configure(
    MGMConfiguration(
      apiKey: 'mgm_proj_your_api_key',
      appVersion: '1.0.0',
      enableDebugLogging: kDebugMode,
    ),
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'My App',
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            MostlyGoodMetrics.track('button_clicked', properties: {
              'screen': 'home',
            });
          },
          child: const Text('Track Event'),
        ),
      ),
    );
  }
}
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
