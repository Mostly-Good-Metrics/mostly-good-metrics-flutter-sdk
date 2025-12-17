import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'logger.dart';
import 'types.dart';
import 'utils.dart';

/// SDK version for metrics headers
const String sdkVersion = '0.2.2';

/// Abstract interface for the network client.
abstract class NetworkClient {
  /// Send events to the API.
  Future<SendResult> sendEvents(
    EventsPayload payload,
    MGMConfiguration config,
  );

  /// Check if we're currently rate limited.
  bool isRateLimited();

  /// Get the time when we can retry after rate limiting.
  DateTime? getRetryAfterTime();
}

/// HTTP-based network client implementation.
class HttpNetworkClient implements NetworkClient {
  DateTime? _retryAfterTime;
  final http.Client _client;

  HttpNetworkClient({http.Client? client}) : _client = client ?? http.Client();

  @override
  bool isRateLimited() {
    if (_retryAfterTime == null) return false;
    return DateTime.now().isBefore(_retryAfterTime!);
  }

  @override
  DateTime? getRetryAfterTime() => _retryAfterTime;

  @override
  Future<SendResult> sendEvents(
    EventsPayload payload,
    MGMConfiguration config,
  ) async {
    if (isRateLimited()) {
      MGMLogger.debug('Rate limited, skipping send');
      return SendResult.rateLimited;
    }

    final url = Uri.parse('${config.baseUrl}/v1/events');
    final body = json.encode(payload.toJson());

    MGMLogger.debug('Sending ${payload.events.length} events to $url');

    try {
      final osVersion = MGMUtils.getOSVersion();
      final response = await _client.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'X-MGM-Key': config.apiKey,
          'User-Agent': 'MostlyGoodMetrics-Flutter/$sdkVersion',
          // SDK identification headers for metrics
          'X-MGM-SDK': 'flutter',
          'X-MGM-SDK-Version': sdkVersion,
          'X-MGM-Platform': MGMUtils.getPlatformName(),
          if (osVersion != null) 'X-MGM-Platform-Version': osVersion,
        },
        body: body,
      );

      MGMLogger.debug('Response status: ${response.statusCode}');

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return SendResult.success;
      }

      if (response.statusCode == 429) {
        // Rate limited
        _handleRateLimitResponse(response);
        return SendResult.rateLimited;
      }

      if (response.statusCode >= 500) {
        // Server error - retry later
        MGMLogger.warning(
          'Server error: ${response.statusCode} - ${response.body}',
        );
        return SendResult.failure;
      }

      // Client error - likely won't succeed on retry
      MGMLogger.error(
        'Client error: ${response.statusCode} - ${response.body}',
      );
      return SendResult.failure;
    } on SocketException catch (e) {
      MGMLogger.error('Network error', e);
      return SendResult.failure;
    } on http.ClientException catch (e) {
      MGMLogger.error('HTTP client error', e);
      return SendResult.failure;
    } catch (e) {
      MGMLogger.error('Unknown error sending events', e);
      return SendResult.failure;
    }
  }

  void _handleRateLimitResponse(http.Response response) {
    final retryAfterHeader = response.headers['retry-after'];

    if (retryAfterHeader != null) {
      final retryAfterSeconds = int.tryParse(retryAfterHeader);
      if (retryAfterSeconds != null) {
        _retryAfterTime = DateTime.now().add(
          Duration(seconds: retryAfterSeconds),
        );
        MGMLogger.warning(
          'Rate limited, retry after $retryAfterSeconds seconds',
        );
        return;
      }
    }

    // Default to 60 seconds if no header
    _retryAfterTime = DateTime.now().add(const Duration(seconds: 60));
    MGMLogger.warning('Rate limited, retry after 60 seconds (default)');
  }

  /// Clear rate limiting state (for testing).
  void clearRateLimiting() {
    _retryAfterTime = null;
  }
}

/// Mock network client for testing.
class MockNetworkClient implements NetworkClient {
  final List<EventsPayload> sentPayloads = [];
  SendResult resultToReturn = SendResult.success;
  bool _rateLimited = false;
  DateTime? _retryAfterTime;

  @override
  Future<SendResult> sendEvents(
    EventsPayload payload,
    MGMConfiguration config,
  ) async {
    sentPayloads.add(payload);
    return resultToReturn;
  }

  @override
  bool isRateLimited() => _rateLimited;

  @override
  DateTime? getRetryAfterTime() => _retryAfterTime;

  void setRateLimited(bool limited, {Duration? retryAfter}) {
    _rateLimited = limited;
    if (limited && retryAfter != null) {
      _retryAfterTime = DateTime.now().add(retryAfter);
    } else {
      _retryAfterTime = null;
    }
  }
}
