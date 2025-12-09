import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mostly_good_metrics/mostly_good_metrics.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize the SDK
  await MostlyGoodMetrics.configure(
    // ignore: prefer_const_constructors
    MGMConfiguration(
      apiKey: 'your_api_key_here', // Replace with your API key
      appVersion: '1.0.0',
      environment: kDebugMode ? 'development' : 'production',
      enableDebugLogging: kDebugMode,
      trackAppLifecycleEvents: true,
    ),
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MostlyGoodMetrics Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _userIdController = TextEditingController();
  int _pendingEventCount = 0;
  String? _currentUserId;
  String? _currentSessionId;

  @override
  void initState() {
    super.initState();
    _refreshState();
  }

  Future<void> _refreshState() async {
    final count = await MostlyGoodMetrics.getPendingEventCount();
    setState(() {
      _pendingEventCount = count;
      _currentUserId = MostlyGoodMetrics.userId;
      _currentSessionId = MostlyGoodMetrics.sessionId;
    });
  }

  @override
  void dispose() {
    _userIdController.dispose();
    super.dispose();
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('MostlyGoodMetrics Example'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SDK Status',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text('Pending Events: $_pendingEventCount'),
                    Text(
                      'User ID: ${_currentUserId ?? 'Not set'}',
                    ),
                    Text(
                      'Session ID: ${_currentSessionId?.substring(0, 8) ?? 'N/A'}...',
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _refreshState,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh'),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // User Identity Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'User Identity',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _userIdController,
                      decoration: const InputDecoration(
                        labelText: 'User ID',
                        hintText: 'Enter user ID',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              final userId = _userIdController.text.trim();
                              if (userId.isNotEmpty) {
                                await MostlyGoodMetrics.identify(userId);
                                _showSnackBar('Identified as $userId');
                                _refreshState();
                              }
                            },
                            child: const Text('Identify'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              await MostlyGoodMetrics.resetIdentity();
                              _userIdController.clear();
                              _showSnackBar('Identity reset');
                              _refreshState();
                            },
                            child: const Text('Reset Identity'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Track Events Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Track Events',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),

                    // Simple events
                    ElevatedButton.icon(
                      onPressed: () {
                        MostlyGoodMetrics.track('button_clicked');
                        _showSnackBar('Tracked: button_clicked');
                        _refreshState();
                      },
                      icon: const Icon(Icons.touch_app),
                      label: const Text('Track Button Click'),
                    ),
                    const SizedBox(height: 8),

                    ElevatedButton.icon(
                      onPressed: () {
                        MostlyGoodMetrics.track('page_viewed', properties: {
                          'page_name': 'home',
                          'scroll_depth': 75,
                        });
                        _showSnackBar('Tracked: page_viewed');
                        _refreshState();
                      },
                      icon: const Icon(Icons.visibility),
                      label: const Text('Track Page View'),
                    ),
                    const SizedBox(height: 8),

                    ElevatedButton.icon(
                      onPressed: () {
                        MostlyGoodMetrics.track('purchase_completed',
                            properties: {
                              'product_id': 'SKU-12345',
                              'product_name': 'Premium Widget',
                              'price': 29.99,
                              'currency': 'USD',
                              'quantity': 1,
                              'category': 'widgets',
                            });
                        _showSnackBar('Tracked: purchase_completed');
                        _refreshState();
                      },
                      icon: const Icon(Icons.shopping_cart),
                      label: const Text('Track Purchase'),
                    ),
                    const SizedBox(height: 8),

                    ElevatedButton.icon(
                      onPressed: () {
                        MostlyGoodMetrics.track('search_performed',
                            properties: {
                              'query': 'flutter sdk',
                              'results_count': 42,
                              'filters': {
                                'category': 'development',
                                'sort': 'relevance',
                              },
                            });
                        _showSnackBar('Tracked: search_performed');
                        _refreshState();
                      },
                      icon: const Icon(Icons.search),
                      label: const Text('Track Search'),
                    ),
                    const SizedBox(height: 8),

                    ElevatedButton.icon(
                      onPressed: () {
                        MostlyGoodMetrics.track('feature_used', properties: {
                          'feature_name': 'dark_mode',
                          'enabled': true,
                          'source': 'settings',
                        });
                        _showSnackBar('Tracked: feature_used');
                        _refreshState();
                      },
                      icon: const Icon(Icons.star),
                      label: const Text('Track Feature Usage'),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Actions Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Actions',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),

                    ElevatedButton.icon(
                      onPressed: () async {
                        await MostlyGoodMetrics.flush();
                        _showSnackBar('Events flushed');
                        _refreshState();
                      },
                      icon: const Icon(Icons.send),
                      label: const Text('Flush Events'),
                    ),
                    const SizedBox(height: 8),

                    ElevatedButton.icon(
                      onPressed: () async {
                        await MostlyGoodMetrics.startNewSession();
                        _showSnackBar('New session started');
                        _refreshState();
                      },
                      icon: const Icon(Icons.replay),
                      label: const Text('Start New Session'),
                    ),
                    const SizedBox(height: 8),

                    OutlinedButton.icon(
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Clear Events'),
                            content: const Text(
                              'Are you sure you want to clear all pending events?',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Clear'),
                              ),
                            ],
                          ),
                        );

                        if (confirm == true) {
                          await MostlyGoodMetrics.clearPendingEvents();
                          _showSnackBar('Events cleared');
                          _refreshState();
                        }
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Clear Pending Events'),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Bulk Events Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Bulk Testing',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Generate multiple events to test batching behavior.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),

                    ElevatedButton.icon(
                      onPressed: () {
                        for (var i = 0; i < 10; i++) {
                          MostlyGoodMetrics.track(
                            'bulk_event',
                            properties: {'index': i},
                          );
                        }
                        _showSnackBar('Tracked 10 events');
                        _refreshState();
                      },
                      icon: const Icon(Icons.flash_on),
                      label: const Text('Track 10 Events'),
                    ),
                    const SizedBox(height: 8),

                    ElevatedButton.icon(
                      onPressed: () {
                        for (var i = 0; i < 100; i++) {
                          MostlyGoodMetrics.track(
                            'bulk_event',
                            properties: {'index': i},
                          );
                        }
                        _showSnackBar('Tracked 100 events');
                        _refreshState();
                      },
                      icon: const Icon(Icons.bolt),
                      label: const Text('Track 100 Events'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
