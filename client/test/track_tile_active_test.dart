import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/widgets/track_tile.dart';

void main() {
  testWidgets('active track tile surfaces a now-playing badge', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TrackTile(
            title: 'Get Your Wish',
            artist: 'Porter Robinson',
            album: 'Nurture',
            duration: '3:38',
            isCurrent: true,
            activeLabel: 'Now playing',
          ),
        ),
      ),
    );

    expect(find.text('Get Your Wish'), findsOneWidget);
    expect(find.text('Now playing'), findsOneWidget);
    expect(find.byIcon(Icons.equalizer), findsOneWidget);
  });
}
