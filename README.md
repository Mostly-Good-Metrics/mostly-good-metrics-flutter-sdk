# MostlyGoodMetrics Flutter SDK

A lightweight Flutter SDK for tracking analytics events with [MostlyGoodMetrics](https://mostlygoodmetrics.com).

## Table of Contents

- [Requirements](#requirements)
- [Platform Support](#platform-support)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Configuration Options](#configuration-options)
- [Automatic Events](#automatic-events)
- [Event Naming](#event-naming)
- [Properties](#properties)
- [Automatic Context](#automatic-context)
- [Manual Flush](#manual-flush)
- [Session Management](#session-management)
- [Automatic Behavior](#automatic-behavior)
- [Error Handling](#error-handling)
- [Debug Logging](#debug-logging)
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
| `$app_opened` | App became active | - |
| `$app_backgrounded` | App went to background | - |

## Event Naming

Event names must:
- Start with a letter (or `$` for system events)
- Contain only alphanumeric characters, underscores, and spaces
- Be 255 characters or less

> **Note:** The `$` prefix is reserved for system events (e.g., `$app_opened`, `$app_backgrounded`). Do not use this prefix for your own events.

```dart
// Valid
MostlyGoodMetrics.track('button_clicked');
MostlyGoodMetrics.track('PurchaseCompleted');
MostlyGoodMetrics.track('step_1_completed');
MostlyGoodMetrics.track('user signed up');  // spaces allowed

// Invalid (will throw MGMError)
MostlyGoodMetrics.track('123_event');      // starts with number
MostlyGoodMetrics.track('event-name');     // contains hyphen
MostlyGoodMetrics.track('$custom_event');  // $ prefix reserved
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

## Automatic Context

The SDK automatically includes context information with every event batch:

| Field | Description | Example |
|-------|-------------|---------|
| `platform` | The platform where the app is running | `ios`, `android`, `web`, `macos`, `windows`, `linux` |
| `app_version` | App version (if configured) | `1.2.3` |
| `app_build_number` | App build number (if configured) | `42` |
| `os_version` | Operating system version | `iOS 17.4`, `Android 14` |
| `user_id` | User identifier (if set via `identify()`) | `user_123` |
| `session_id` | Current session identifier | `a1b2c3d4-...` |
| `environment` | Environment name | `production`, `staging` |
| `device_manufacturer` | Device manufacturer (iOS/macOS only) | `Apple` |
| `locale` | User's locale | `en_US` |
| `timezone` | User's timezone | `EST`, `UTC+5` |

This context is included automatically—no additional code required.

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

- **Persists events** to local storage, surviving app restarts
- **Batches events** for efficient network usage
- **Flushes on interval** (default: every 30 seconds)
- **Flushes on background** when the app goes to background
- **Retries on failure** for network errors (events are preserved)
- **Persists user ID** across app launches
- **Generates session IDs** per app launch

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
