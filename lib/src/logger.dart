import 'dart:developer' as developer;

/// Internal logger for MostlyGoodMetrics SDK.
class MGMLogger {
  static bool _enabled = false;

  /// Enable or disable debug logging.
  static void setEnabled(bool enabled) {
    _enabled = enabled;
  }

  /// Whether debug logging is enabled.
  static bool get isEnabled => _enabled;

  /// Log a debug message.
  static void debug(String message) {
    if (_enabled) {
      developer.log('[MostlyGoodMetrics] $message', name: 'MGM');
    }
  }

  /// Log a warning message.
  static void warning(String message) {
    if (_enabled) {
      developer.log('[MostlyGoodMetrics] WARNING: $message', name: 'MGM');
    }
  }

  /// Log an error message.
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    if (_enabled) {
      developer.log(
        '[MostlyGoodMetrics] ERROR: $message',
        name: 'MGM',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
