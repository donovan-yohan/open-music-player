#!/usr/bin/env python3
"""Finite consuming-source contract. Does not claim rendered/gesture acceptance.

Run directly, or pass --source-root /path/to/android to inspect an integration.
Music collections, including catalog artist/group/edition lists, use the shared
row anatomy. Settings rows and full detail/action sheets remain outside this fence.
"""
from pathlib import Path
import argparse
import re
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--source-root', type=Path)
args, remaining = parser.parse_known_args()
ROOT = args.source_root or Path(__file__).resolve().parents[1]
PRODUCT = ROOT / 'app/src/main/kotlin/com/soundq/android/product'


def source(relative):
    return (PRODUCT / relative).read_text()


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


def without_sheets(text):
    # Mask quoted strings before counting delimiters. Detail/action sheets may
    # show complete identity. List rows may not rebuild that identity locally.
    masked = re.sub(r'"(?:\\.|[^"\\])*"', lambda m: ' ' * len(m[0]), text)
    spans = []
    for match in re.finditer(r'SoundQSheet\(', masked):
        # Jam's outer sheet is the screen host, not a row's contextual surface.
        if text[match.end():].startswith('"Jam",'):
            continue
        cursor = match.end()
        depth = 1
        while depth:
            depth += (masked[cursor] == '(') - (masked[cursor] == ')')
            cursor += 1
        opening = masked.index('{', cursor)
        cursor = opening + 1
        depth = 1
        while depth:
            depth += (masked[cursor] == '{') - (masked[cursor] == '}')
            cursor += 1
        spans.append((match.start(), cursor))
    for start, end in reversed(spans):
        text = text[:start] + ' ' * (end - start) + text[end:]
    return text


class SharedMediaRowCallersContract(unittest.TestCase):
    def shared(self, text, count=1):
        self.assertEqual(text.count('SoundQMediaRow('), count)
        self.assertNotIn('SoundQRow(', text, 'song identity must use the shared row')
        self.assertNotRegex(text, r'Text\(\s*(?:(?:track|song|row(?:\.track)?)\??\.?(?:title|artist)|title)\b')

    def test_playlist_branches_share_anatomy_and_forward_artwork(self):
        text = source('playlists/PlaylistDetailScreen.kt')
        self.shared(without_sheets(text), 2)
        self.assertIn('artwork:@Composable (com.soundq.android.data.Track,()->Boolean)->Unit={_,_->}', text)
        self.assertEqual(text.count('artwork(track,rowCurrent)'), 2)
        self.assertIn('artwork={key->', text)
        self.assertIn('artwork(track,{lifetime.current()&&rowLifetime.current()})', text)
        self.assertIn('Starts ${mixTime(plan.clips[index].start)}', text)
        self.assertNotIn('contentPadding = PaddingValues(SoundQ.spacing.gutter)', text)
        self.assertNotIn('verticalArrangement = Arrangement.spacedBy(SoundQ.spacing.medium)', text)
        self.assertIn('SoundQSwipeQueue(track.title,reveal,capture!=null,queue)', text)
        self.assertIn('if(admit())capture?.let {onPlayAt(it,track.id,index)}', text)
        self.assertIn('onQueue(it,index,track,lifetime::current)', text)
        self.assertIn('orderActions.move(orderTarget,moved.id,detail.tracks.map {it.id},intent.to)', text)
        for label in ['Play', 'Add to listening queue', 'Remove from playlist']:
            self.assertIn('SoundQButton("' + label + '"', text)

    def test_playlist_grip_keeps_drag_and_scroll_owners(self):
        text = source('playlists/PlaylistMemberOrderList.kt')
        self.shared(text)
        self.assertIn('artwork:(@Composable (String)->Unit)?=null', text)
        self.assertIn('artwork?.let {slot->{slot(row.occurrence)}}', text)
        for token in ['detectDragGestures(', 'userScrollEnabled=active==null',
                      'g.scrolled(list.scrollBy(delta))', 'val intent=g.complete()',
                      'if(intent!=null)dispatch(intent)', 'active==null&&admit()',
                      'LocalPinnableContainer.current', 'onDispose {cancel()}',
                      '"Move earlier"', '"Move later"', '"Remove from playlist"']:
            self.assertIn(token, text)
        self.assertIn('supporting="${index+1}"', text)
        self.assertLess(text.index('SoundQMediaRow('), text.index('CompositionLocalProvider(LocalViewConfiguration'),
                        'artwork must remain flush to the leading edge, grip follows it')

    def test_downloads_share_anatomy_and_keep_scoped_actions(self):
        text = source('offline/DownloadsScreen.kt')
        self.shared(without_sheets(text))
        self.assertIn('TrackArtwork(model.graph,scope,row.track,', text)
        self.assertIn('{rowValid()&&!model.playback.value.localOnly}', text)
        self.assertIn('sourceOwner=lifetime to playback.localOnly', text)
        self.assertIn('val rowValid={valid()&&lifetime.current()}', text)
        self.assertIn('SoundQSwipeQueue(row.track.title,reveal,queueEnabled,quickQueue,explicitQueue=queue,current=current)', text)
        self.assertIn('if(admit())', text)
        self.assertNotIn('contentPadding=PaddingValues(SoundQ.spacing.gutter)', text)
        self.assertNotIn('Text(row.track.title', without_sheets(text))
        self.assertNotIn('Text(row.track.artist', text)
        self.assertIn('if(menu)SoundQSheet(', text)
        self.assertIn('remember(scope,row.track.id,row.status){mutableStateOf(false)}', text,
                      'progress byte publications must not dismiss the Cancel menu')
        for token in ['model.cancelDownload(scope,row,valid)', 'model.playDownload(scope,row,rowValid)',
                      'model.enqueueDownload(scope,row,rowValid,next=true)', 'model.retryDownload(scope,row,rowValid)',
                      'confirmation=listOf(row)', 'model.removeDownloads(scope,captured,valid)',
                      'queueEnabled=!state.rejected&&row.status==DownloadStatus.Complete']:
            self.assertIn(token, text)
        for label in ['Cancel download', 'Play device copy', 'Queue', 'Play next', 'Retry download', 'Remove device copy']:
            self.assertIn('SoundQButton("' + label + '"', text)

    def test_jam_songs_use_shared_rows_and_preserve_host_decisions(self):
        text = source('jam/JamHostPanel.kt')
        self.shared(without_sheets(text), 2)
        self.assertNotIn('Text(song?.title', text)
        self.assertIn('JamSongRows {', text)
        self.assertIn('requiredWidth(maxWidth+SoundQ.spacing.gutter*2)', text)
        for token in ['selected.size<20', 'library.rows.filter {it.id in selected}',
                      'host.decide(it,request,true)', 'host.decide(it,request,false)',
                      'host.decide(it,request,true,true)', 'request.status=="pending"',
                      'enabled=!state.busy']:
            self.assertIn(token, text)
        states = re.search(r'if\(request.status in setOf\(([^)]*)\)\)', text)
        self.assertIsNotNone(states)
        self.assertEqual(set(re.findall(r'"([^"]+)"', states.group(1))),
                         {'pending', 'approved', 'importing', 'ready', 'uncertain'})
        self.assertGreaterEqual(text.count('LibraryMetadataContent(memberDurationMetadata('), 2)
        self.assertGreaterEqual(text.count('artwork={TrackArtwork('), 2)
        self.assertIn('request.source?.title ?: song?.title', text)
        self.assertNotIn('?: "Song request"', text)
        self.assertIn('if(showInvitation)SoundQSheet("Invitation"', text)
        self.assertIn('if(confirmEnd)SoundQSheet("End Jam?"', text)
        self.assertIn('Guests lose access. Playback and added songs stay.', text)

    def test_catalog_media_collections_are_touching_with_individually_inset_headers(self):
        text = source('catalog/CatalogScreen.kt')
        rows = between(text, 'itemsIndexed(album.tracks', 'else if(state.artist!=null)')
        self.shared(rows)
        self.assertIn('subtitle=row.artist ?: album.artist.orEmpty()', rows)
        self.assertIn('supporting=listOfNotNull(row.position', rows)
        self.assertIn('onActivate={actions.recording(state,row,index)}', rows)
        self.assertIn('onMore={actions.recording(state,row,index)}', rows)
        self.assertIn('duration(row.durationMs)', rows)
        # Hotate F3 applies touching anatomy to artist/group/server-edition collections too.
        self.assertIn('LazyColumn(Modifier.fillMaxSize(),state=scroll) {', text)
        self.assertNotIn('contentPadding=', text)
        self.assertIn('catalogHeader(content:@Composable ()->Unit)', text)
        self.assertIn('Column(Modifier.fillMaxWidth().padding(SoundQ.spacing.gutter)', text)
        self.assertIn('SoundQMediaRow(row.name,row.description', text)
        self.assertIn('SoundQMediaRow(row.title,artist.row.name', text)
        self.assertIn('SoundQMediaRow(row.title,row.artist.orEmpty()', text)
        self.assertIn('enabled=row.id!=null', text)
        self.assertIn('actions.groupEditions(state)', text)
        self.assertIn('SoundQIconButton(SoundQIcon.Back,"Back"', text)
        self.assertIn('SoundQIconButton(SoundQIcon.Search,"Submit catalog search"', text)
        self.assertIn('Recording MusicBrainz ID:', text)
        self.assertIn('"Check Library"', text)
        self.assertNotIn('Artists are from MusicBrainz. Albums search metadata', text)

    def test_discovery_results_share_row_without_changing_inspect_import_boundary(self):
        text = source('discovery/DiscoverScreen.kt')
        rows = between(text, 'items(results.rows', '            } else {')
        self.shared(rows)
        self.assertIn('subtitle=row.artist', rows)
        self.assertIn('row.provider.label', rows)
        self.assertIn('duration(row.durationMs)', rows)
        self.assertIn('DiscoveryArtwork(model.graph.mediaClient,row.thumbnailUrl', rows)
        self.assertIn('repository.state.value.results===results', rows)
        self.assertIn('Row(verticalAlignment=Alignment.Bottom)', text)
        self.assertIn('LazyColumn(Modifier.fillMaxSize(),state=scroll)', text)
        self.assertEqual(rows.count('repository.inspect(it,row)'), 2)
        entities = between(text, 'items(entities)', '    state.inspected?.let')
        self.shared(entities)
        self.assertIn('repository.refine(route,entity)', entities)
        self.assertNotIn('submitSourceImport', entities)
        self.assertNotIn('contentPadding=PaddingValues(SoundQ.spacing.gutter)', text)
        self.assertIn('if(!choice.valid())', text)
        self.assertIn('model.submitSourceImport(it,choice)', text)


if __name__ == '__main__':
    unittest.main(argv=[__file__, *remaining])
