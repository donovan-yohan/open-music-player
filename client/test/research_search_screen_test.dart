import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/discovery/discovery_models.dart';
import 'package:open_music_player/core/discovery/research_models.dart';
import 'package:open_music_player/core/discovery/research_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/search/search_screen.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'shows baseline immediately and applies only newer revisions in stable rows',
    (tester) async {
      final service = _FakeResearchService()
        ..createSnapshots.add(
          _snapshot(
            jobId: 'job-1',
            status: 'running',
            revision: 1,
            candidates: const [
              ('candidate-a', 'Baseline A'),
              ('candidate-b', 'Baseline B'),
            ],
          ),
        )
        ..getSnapshots.addAll([
          _snapshot(
            jobId: 'job-1',
            status: 'running',
            revision: 2,
            stage: 'direct_judge',
            candidates: const [
              ('candidate-b', 'Enhanced B'),
              ('candidate-a', 'Enhanced A'),
            ],
          ),
          _snapshot(
            jobId: 'job-1',
            status: 'completed',
            revision: 1,
            candidates: const [
              ('candidate-a', 'Stale A'),
              ('candidate-b', 'Stale B'),
            ],
          ),
        ]);
      await _pumpSearch(tester, service);

      await _submitResearch(tester, 'find shelter');

      expect(find.text('Baseline A'), findsOneWidget);
      expect(find.text('Baseline B'), findsOneWidget);
      expect(service.getCalls, 0);
      final rowA = find.byKey(const ValueKey('research_candidate_candidate-a'));
      final rowB = find.byKey(const ValueKey('research_candidate_candidate-b'));
      final originalRowA = tester.element(rowA);

      await _firePoll(tester);

      expect(find.text('Enhanced A'), findsOneWidget);
      expect(find.text('Enhanced B'), findsOneWidget);
      expect(identical(originalRowA, tester.element(rowA)), isTrue);
      expect(tester.getTopLeft(rowA).dy, lessThan(tester.getTopLeft(rowB).dy));

      await _firePoll(tester);

      expect(find.text('Enhanced A'), findsOneWidget);
      expect(find.text('Enhanced B'), findsOneWidget);
      expect(find.text('Stale A'), findsNothing);
      expect(service.getCalls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('cancel_requested keeps polling until cancelled', (tester) async {
    final service = _FakeResearchService()
      ..createSnapshots.add(
        _snapshot(jobId: 'job-1', status: 'running', revision: 1),
      )
      ..cancelSnapshots.add(
        _snapshot(jobId: 'job-1', status: 'cancel_requested', revision: 1),
      )
      ..getSnapshots.add(
        _snapshot(jobId: 'job-1', status: 'cancelled', revision: 1),
      );
    await _pumpSearch(tester, service);
    await _submitResearch(tester, 'find shelter');

    await tester.tap(find.byKey(const ValueKey('research_cancel')));
    await tester.pump();

    expect(service.cancelCalls, 1);
    expect(find.byKey(const ValueKey('research_cancel')), findsOneWidget);

    await _firePoll(tester);

    expect(service.getCalls, 1);
    expect(find.byKey(const ValueKey('research_cancel')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed cancel request keeps the active job polling', (
    tester,
  ) async {
    final cancelGate = Completer<ResearchSnapshot>();
    final service = _FakeResearchService()
      ..createSnapshots.add(
        _snapshot(jobId: 'job-1', status: 'running', revision: 1),
      )
      ..getSnapshots.add(
        _snapshot(jobId: 'job-1', status: 'completed', revision: 1),
      )
      ..cancelGate = cancelGate;
    await _pumpSearch(tester, service);
    await _submitResearch(tester, 'find shelter');

    await tester.tap(find.byKey(const ValueKey('research_cancel')));
    cancelGate.completeError(StateError('cancel transport failed'));
    await tester.pump();

    expect(find.byKey(const ValueKey('assist_status_banner')), findsOneWidget);
    await _firePoll(tester);

    expect(service.getCalls, 1);
    expect(find.byKey(const ValueKey('research_cancel')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('retry clears the previous degradation authoritatively', (
    tester,
  ) async {
    final service = _FakeResearchService()
      ..createSnapshots.add(
        _snapshot(
          jobId: 'job-1',
          status: 'degraded',
          revision: 1,
          retrySafe: true,
          degradation: const ResearchDegradation(
            code: 'model_unavailable',
            retryable: true,
          ),
        ),
      )
      ..retrySnapshots.add(
        _snapshot(
          jobId: 'job-1',
          status: 'queued',
          revision: 1,
          retrySafe: true,
        ),
      );
    await _pumpSearch(
      tester,
      service,
      pollDelays: const [Duration(days: 1)],
    );
    await _submitResearch(tester, 'find shelter');

    expect(find.textContaining('Research degraded'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('research_retry')));
    await tester.pump();

    expect(service.retryCalls, 1);
    expect(find.textContaining('Research degraded'), findsNothing);
    expect(find.textContaining('Researching: baseline'), findsOneWidget);
    expect(find.byKey(const ValueKey('research_cancel')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final operation in ['cancel', 'retry']) {
    testWidgets('stale $operation failure cannot overwrite a newer request', (
      tester,
    ) async {
      final operationGate = Completer<ResearchSnapshot>();
      final service = _FakeResearchService()
        ..createSnapshots.addAll([
          _snapshot(
            jobId: 'job-1',
            status: operation == 'cancel' ? 'running' : 'degraded',
            revision: 1,
            retrySafe: operation == 'retry',
            degradation: operation == 'retry'
                ? const ResearchDegradation(
                    code: 'timeout',
                    retryable: true,
                  )
                : null,
            candidates: const [('candidate-old', 'Old result')],
          ),
          _snapshot(
            jobId: 'job-2',
            status: 'running',
            revision: 1,
            candidates: const [('candidate-new', 'New result')],
          ),
        ]);
      if (operation == 'cancel') {
        service.cancelGate = operationGate;
      } else {
        service.retryGate = operationGate;
      }
      await _pumpSearch(
        tester,
        service,
        pollDelays: const [Duration(days: 1)],
      );
      await _submitResearch(tester, 'first prompt');

      final actionKey = operation == 'cancel'
          ? const ValueKey('research_cancel')
          : const ValueKey('research_retry');
      await tester.tap(find.byKey(actionKey));
      await tester.pump();

      await _submitResearch(tester, 'second prompt');
      expect(find.text('New result'), findsOneWidget);

      operationGate.completeError(StateError('stale $operation failure'));
      await tester.pump();
      await tester.pump();

      expect(find.text('New result'), findsOneWidget);
      expect(find.byKey(const ValueKey('assist_status_banner')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('disposing the screen stops research polling', (tester) async {
    final service = _FakeResearchService()
      ..createSnapshots.add(
        _snapshot(jobId: 'job-1', status: 'running', revision: 1),
      );
    await _pumpSearch(tester, service);
    await _submitResearch(tester, 'find shelter');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));

    expect(service.getCalls, 0);
    expect(service.eventCalls, 0);
  });
}

Future<void> _pumpSearch(
  WidgetTester tester,
  _FakeResearchService service, {
  List<Duration> pollDelays = const [Duration(milliseconds: 1)],
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final apiClient = ApiClient(storage: SecureStorage(), dio: Dio());
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider<QueueProvider>(
          create: (_) => QueueProvider(_QueueApiClient()),
        ),
      ],
      child: MaterialApp(
        home: SearchScreen(
          researchService: service,
          researchPollDelays: pollDelays,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _submitResearch(WidgetTester tester, String prompt) async {
  if (find.text('Assist').evaluate().isNotEmpty) {
    final assistButton = find.text('Assist');
    final segmentedButton = tester.widget<SegmentedButton<bool>>(
      find.byType(SegmentedButton<bool>),
    );
    if (!segmentedButton.selected.contains(true)) {
      await tester.tap(assistButton);
      await tester.pump();
    }
  }
  await tester.enterText(
    find.byKey(const ValueKey('search_assist_input')),
    prompt,
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
  await tester.pump();
}

Future<void> _firePoll(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

class _FakeResearchService implements ResearchJobService {
  final Queue<ResearchSnapshot> createSnapshots = Queue<ResearchSnapshot>();
  final Queue<ResearchSnapshot> getSnapshots = Queue<ResearchSnapshot>();
  final Queue<ResearchSnapshot> cancelSnapshots = Queue<ResearchSnapshot>();
  final Queue<ResearchSnapshot> retrySnapshots = Queue<ResearchSnapshot>();
  Completer<ResearchSnapshot>? cancelGate;
  Completer<ResearchSnapshot>? retryGate;
  int getCalls = 0;
  int eventCalls = 0;
  int cancelCalls = 0;
  int retryCalls = 0;

  @override
  Future<ResearchSnapshot> create({
    required String query,
    List<String> providers = const ['youtube', 'soundcloud'],
    int limit = 12,
    String? idempotencyKey,
  }) async =>
      createSnapshots.removeFirst();

  @override
  Future<ResearchSnapshot> get(String jobId) async {
    getCalls++;
    return getSnapshots.removeFirst();
  }

  @override
  Future<ResearchEventPage> events(
    String jobId, {
    int afterSequence = 0,
  }) async {
    eventCalls++;
    return ResearchEventPage(events: const [], afterSequence: afterSequence);
  }

  @override
  Future<ResearchSnapshot> cancel(String jobId) {
    cancelCalls++;
    return cancelGate?.future ?? Future.value(cancelSnapshots.removeFirst());
  }

  @override
  Future<ResearchSnapshot> retry(String jobId) {
    retryCalls++;
    return retryGate?.future ?? Future.value(retrySnapshots.removeFirst());
  }

  @override
  Future<SourceSelectionDecision> review({
    required String jobId,
    required String candidateId,
    required SourceSelectionAction action,
    String? reason,
    String? idempotencyKey,
  }) =>
      throw UnimplementedError();
}

class _QueueApiClient extends ApiClient {
  @override
  Future<QueueState> getQueue() async => QueueState.fromJson({
        'items': <Map<String, dynamic>>[],
        'currentPosition': 0,
      });

  @override
  Future<List<MixPlan>> listMixPlans({int limit = 50, int offset = 0}) async =>
      const [];
}

ResearchSnapshot _snapshot({
  required String jobId,
  required String status,
  required int revision,
  String stage = 'baseline',
  bool retrySafe = false,
  ResearchDegradation? degradation,
  List<(String, String)> candidates = const [('candidate-a', 'Candidate A')],
}) {
  final researchCandidates = candidates
      .map(
        (candidate) => ResearchCandidate(
          candidateId: candidate.$1,
          provider: 'youtube',
          sourceUrl: 'https://youtube.example/${candidate.$1}',
          title: candidate.$2,
          downloadable: true,
          playable: false,
          sourceQuality: const DiscoverySourceQuality(
            score: 90,
            classification: 'official_audio',
            recommendation: 'recommended',
            confidence: 0.9,
          ),
        ),
      )
      .toList();
  final now = DateTime.utc(2026, 7, 17);
  return ResearchSnapshot(
    job: ResearchJob(
      id: jobId,
      status: status,
      retrySafe: retrySafe,
      attempts: 1,
      maxAttempts: 2,
      latestRevision: revision,
      latestRevisionId: '$jobId-revision-$revision',
      createdAt: now,
      updatedAt: now,
    ),
    revisions: [
      ResearchRevision(
        id: '$jobId-revision-$revision',
        jobId: jobId,
        number: revision,
        kind: revision == 1 ? 'baseline' : 'enhancement',
        payload: ResearchRevisionPayload(
          stage: stage,
          query: 'query',
          candidates: researchCandidates,
          recommendations: [
            if (researchCandidates.isNotEmpty)
              ResearchRecommendation(
                candidateId: researchCandidates.first.candidateId,
                rank: 1,
                confidence: 0.9,
                classification: 'official_audio',
              ),
          ],
          provenanceSource: 'deterministic',
        ),
        validatedAt: now,
      ),
    ],
    latestDegradation: degradation,
  );
}
