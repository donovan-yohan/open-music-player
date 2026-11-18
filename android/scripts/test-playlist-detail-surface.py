#!/usr/bin/env python3
"""Playlist detail consumer structure; not native layout, paint or input proof.

The mounted PlaylistDetailSurfaceTest exercises production layout and callbacks.
This fast check rejects the nested fixed-height predecessor without an SDK.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import unittest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument('--output', type=Path, help='Compile exact production sampling/drag bodies with a standalone Kotlin compiler')
args, remaining = parser.parse_known_args()
product = args.root / 'app/src/main/kotlin/com/soundq/android/product'
detail = (product / 'playlists/PlaylistDetailScreen.kt').read_text()
members = (product / 'playlists/PlaylistMemberOrderList.kt').read_text()
menus = (product / 'playlists/PlaylistManagementControls.kt').read_text()
sheets = (args.root / 'designsystem/src/main/kotlin/com/soundq/designsystem/ProductComponents.kt').read_text()


class PlaylistDetailSurfaceContract(unittest.TestCase):
    def test_production_sampling_and_drag_completion(self):
        if args.output is None:
            self.skipTest('Pass --output for the SDK-free Kotlin sampling/drag probe')
        args.output.mkdir(parents=True, exist_ok=True)
        start = members.index('    fun sample(')
        end = members.index('    DisposableEffect(revision,order)', start)
        sample = members[start:end]
        drag = members[members.index('private class PlaylistMemberDragSession'):]
        source = '''import com.soundq.designsystem.*
data class Item(val key:Any,val index:Int,val offset:Int,val size:Int)
class Layout(val visibleItemsInfo:List<Item>)
class ListState(val layoutInfo:Layout)
private class SamplingFixture(val list:ListState) {
    val headerCount=1
    val measured=mutableMapOf<String,QueueItemBounds>()
''' + sample + '''}
''' + drag + '''
fun main() {
    val order=(1..39).map {it.toString()}
    val items=listOf(Item(0,0,-20,40))+order.mapIndexed {i,id->Item(id,i+1,20+i*72,72)}
    val sampler=SamplingFixture(ListState(Layout(items)))
    val g=PlaylistMemberDragSession(order,"1",56f,20f,72f)
    val bounds=sampler.sample(g)
    check(bounds.map {it.index}==order.indices.toList()) {"Feedback header leaked into member ordinals: ${bounds.map {it.index}}"}
    check(bounds.map {it.occurrence}==order)
    g.follow(150f,bounds)
    check(g.target==1) {"First member drag must target second member, not lazy header index ${g.target}"}
    check(g.neighborOffset(1)==-72f)
    check(g.release()==null)
    check(g.complete()==QueueMoveIntent("1",order,1))
    check(g.complete()==null)
    val held=PlaylistMemberDragSession(order,"1",56f,20f,72f)
    held.follow(500f,bounds)
    val step=held.edgeStep(0f,500f,48f,1f,16f)
    check(step==16f)
    held.scrolled(step)
    check(held.translation==460f)
    held.cancel();held.release();check(held.complete()==null)
    check(held.edgeStep(0f,500f,48f,1f,16f)==0f)
    println("PASS exact production sampling: 39 member ordinals, header exclusion, reorder target, once-only settle, held edge scroll and cancel")
}
'''
        generated=args.output / 'PlaylistSampling.kt'
        generated.write_text(source)
        queue=args.root / 'designsystem/src/main/kotlin/com/soundq/designsystem/QueueDrag.kt'
        jar=args.output / 'sampling.jar'
        commands=[['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',str(queue),str(generated),'-include-runtime','-d',str(jar)],
                  ['java','-Xmx256m','-XX:ActiveProcessorCount=1','-jar',str(jar)]]
        (args.output / 'manifest.json').write_text(json.dumps({'boundary':'Exact production Kotlin with list-layout declarations; not mounted Compose',
            'sample_sha256':hashlib.sha256(sample.encode()).hexdigest(),'drag_sha256':hashlib.sha256(drag.encode()).hexdigest(),'commands':commands},indent=2)+'\n')
        for command in commands:
            result=subprocess.run(command,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            with (args.output / 'execution.log').open('a') as log:
                log.write(json.dumps(command)+'\n'+result.stdout+f'\nexit={result.returncode}\n')
            self.assertEqual(0,result.returncode,result.stdout)

    def test_bounded_body_not_a_reorder_list_inside_a_lazy_item(self):
        self.assertIn('Column(Modifier.fillMaxSize())', detail)
        self.assertIn('Box(Modifier.weight(1f).fillMaxWidth())', detail)
        self.assertNotIn('else if(orderActions!=null && !detail.playlist.draft.isPublic) item', detail)
        self.assertNotIn('MOTION_SHEET_MEDIUM', members)
        self.assertIn('LazyColumn(modifier.fillMaxSize()', members)
        self.assertIn('header=feedback', detail)

    def test_headers_never_become_member_ordinals(self):
        self.assertIn('val headerCount=if(header!=null)1 else 0', members)
        self.assertIn('if(item.index<headerCount)return@forEach', members)
        self.assertIn('item.index-headerCount', members)
        self.assertIn('list.scrollToItem(index+headerCount)', members)

    def test_existing_branch_and_gesture_authority_stays_in_place(self):
        for text in ['!detail.playlist.draft.isPublic', 'BlendStatus.Ready && plan!=null',
                     'orderActions.move(orderTarget,moved.id,detail.tracks.map {it.id},intent.to)',
                     'onQueue(it,index,track,lifetime::current)', 'artwork(track,rowCurrent)',
                     '{blendCapture?.let(onGenerate)}']:
            self.assertIn(text, detail)
        for text in ['userScrollEnabled=active==null', 'g.scrolled(list.scrollBy(delta))',
                     'onDispose {cancel()}', 'if(intent!=null)dispatch(intent)',
                     '"Move earlier"', '"Move later"', '"Remove from playlist"']:
            self.assertIn(text, members)

    def test_harmonic_journey_clicks_fixed_header_without_scrolling(self):
        journey = (args.root / 'app/src/androidTest/kotlin/com/soundq/android/HarmonicPlaylistJourneyTest.kt').read_text()
        interactions = [line for line in journey.splitlines()
                        if 'onNodeWithContentDescription("Find harmonic matches")' in line]
        self.assertEqual(2, len(interactions))
        for interaction in interactions:
            self.assertNotIn('.performScrollTo()', interaction)
            self.assertIn('.assertIsDisplayed().performClick()', interaction)

    def test_playlist_menu_uses_real_song_action_owner_and_opt_in_sheet(self):
        menu = menus.split('@Composable fun PlaylistManagementMenu', 1)[1].split('@Composable fun PlaylistMemberMenu', 1)[0]
        self.assertIn('presentation=SoundQSheetPresentation.Actions', menu)
        self.assertEqual(3, menu.count('SongActionRow('))
        self.assertNotIn('SoundQRow(', menu)
        self.assertIn('actions.askDelete(target)?.let(onDelete)', menu)
        self.assertIn('enabled=enabled', menu)
        self.assertIn('mediaRowBottomRule()', menu)
        self.assertIn('presentation:SoundQSheetPresentation=SoundQSheetPresentation.Form', sheets)


if __name__ == '__main__':
    unittest.main(argv=[__file__, *remaining])
