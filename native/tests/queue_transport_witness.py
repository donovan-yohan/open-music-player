#!/usr/bin/env python3
"""Deterministic populated transport allocation witness in a private core copy.

Run after setting repair_support environment. No changes to the input source.
One serial Cargo invocation, two jobs; current reports must not allocate queue
content or invoke the saved-queue serializer, regardless of metadata size.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

MODULE = r'''
#[cfg(test)]
mod queue_transport_witness {
    use super::*;
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::cell::Cell;
    thread_local! {
        static ACTIVE: Cell<bool> = const { Cell::new(false) };
        static BYTES: Cell<usize> = const { Cell::new(0) };
        pub(super) static SAVES: Cell<usize> = const { Cell::new(0) };
    }
    struct Meter;
    #[global_allocator]
    static METER: Meter = Meter;
    unsafe impl GlobalAlloc for Meter {
        unsafe fn alloc(&self, l: Layout) -> *mut u8 {
            if ACTIVE.try_with(|a| a.get()).unwrap_or(false) {
                let _ = BYTES.try_with(|b| b.set(b.get() + l.size()));
            }
            unsafe { System.alloc(l) }
        }
        unsafe fn dealloc(&self, p: *mut u8, l: Layout) { unsafe { System.dealloc(p,l) } }
        unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
            if ACTIVE.try_with(|a| a.get()).unwrap_or(false) {
                let _ = BYTES.try_with(|b| b.set(b.get() + n));
            }
            unsafe { System.realloc(p,l,n) }
        }
    }
    #[test]
    fn reports_never_copy_or_serialize_populated_queue() {
        let c = tests::core();
        let mut observations = Vec::new();
        for count in [261, 0] {
            {
                let mut s=c.state.lock().unwrap();
                s.snapshot.library=(1..=count).map(|id| Track { id, title:"t".repeat(15000), artist:None, album:None, duration_ms:Some(u64::MAX) }).collect();
                s.snapshot.queue=s.snapshot.library.iter().enumerate().map(|(i,t)| Occurrence { id:i as u64+1, track:t.clone() }).collect();
                s.snapshot.selected_occurrence=if count>0 {Some(1)} else {None};
                s.next_occurrence=count as u64+1;
                s.snapshot.error=None;
            }
            let mut bytes=Vec::new();
            for state in [AudioState::Playing,AudioState::Preparing,AudioState::Failed] {
                let cmd=Command::AudioReport {epoch:1,session:0,state,position_ms:u64::MAX,duration_ms:u64::MAX};
                BYTES.with(|b|b.set(0)); SAVES.with(|s|s.set(0));
                ACTIVE.with(|a|a.set(true));
                let r=c.execute(cmd);
                ACTIVE.with(|a|a.set(false));
                let allocation=BYTES.with(|b|b.get()); let serializations=SAVES.with(|s|s.get());
                assert!(r.ok,"{}",r.code);
                assert_eq!(r.snapshot.transport,state);
                assert_eq!(r.snapshot.position_ms,u64::MAX);
                assert!(r.snapshot.queue_unchanged && r.snapshot.queue.is_empty());
                println!("WITNESS count={count} state={state:?} allocated={allocation} saved_serializations={serializations}");
                assert_eq!(serializations,0,"ordinary report serialized queue");
                assert!(allocation<1024,"ordinary report allocated queue content");
                bytes.push(allocation);
            }
            observations.push(bytes);
        }
        assert_eq!(observations[0],observations[1],"allocation scales with populated queue");
        fs::remove_dir_all(&c.root).unwrap();
    }
    #[test]
    fn maximum_ids_selection_cursor_and_next_are_budgeted_before_consumption() {
        let c=tests::core();
        let mut s=c.state.lock().unwrap();
        s.snapshot.library=vec![Track {id:1,title:"\0".repeat(16000),artist:None,album:None,duration_ms:Some(u64::MAX)}];
        s.next_occurrence=u64::MAX-1;
        assert!(c.validate_queue_command(&s,&Command::Select {track_id:1}).is_ok());
        assert!(c.apply(&mut s,Command::QueueAppend {track_id:1},1).is_ok());
        assert_eq!(s.snapshot.queue[0].id,u64::MAX-1);
        assert_eq!(s.next_occurrence,u64::MAX);
        let mut saved=SavedQueue {version:1,queue:s.snapshot.queue.clone(),selected:Some(u64::MAX-1),position_ms:u64::MAX,next_occurrence:u64::MAX};
        let len=Core::saved_queue_bytes(&saved).unwrap().len();
        // Use a legal bounded title and a large optional metadata field to
        // positively control exact byte admission at maximum ID widths.
        saved.queue[0].track.artist=Some("a".repeat(MAX_SAVED_QUEUE_BYTES-len-2));
        // null -> quoted string consumes len-2 bytes.
        let current=Core::saved_queue_bytes(&saved).unwrap().len();
        saved.queue[0].track.artist.as_mut().unwrap().push_str(&"a".repeat(MAX_SAVED_QUEUE_BYTES-current));
        assert_eq!(Core::saved_queue_bytes(&saved).unwrap().len(),MAX_SAVED_QUEUE_BYTES);
        s.snapshot.library=vec![saved.queue[0].track.clone()];
        s.snapshot.queue.clear();
        s.next_occurrence=u64::MAX-1;
        assert_eq!(c.validate_queue_command(&s,&Command::Select {track_id:1}),Ok(()));
        s.snapshot.library[0].artist.as_mut().unwrap().push('a');
        assert_eq!(c.validate_queue_command(&s,&Command::Select {track_id:1}),Err("queue_full"));
        assert_eq!(s.next_occurrence,u64::MAX-1);
        assert!(s.snapshot.queue.is_empty());
        s.next_occurrence=u64::MAX;
        s.snapshot.queue=saved.queue;
        s.snapshot.selected_occurrence=saved.selected;
        s.snapshot.position_ms=u64::MAX;
        assert_eq!(c.validate_queue_command(&s,&Command::QueueAppend {track_id:1}),Err("queue_full"));
        assert_eq!(s.next_occurrence,u64::MAX);
        assert_eq!(s.snapshot.queue.len(),1);
        drop(s); fs::remove_dir_all(&c.root).unwrap();
        println!("PASS maximum-ID-next-overflow-atomic-escaped-scalar-envelope");
    }
}
'''

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--source-root',type=Path,default=Path(__file__).resolve().parents[2]); parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args(); source=args.source_root/'native/core'; output=args.output
    assert not output.exists(), 'witness output must be private and fresh'
    shutil.copytree(source,output,ignore=shutil.ignore_patterns('target'))
    lib=output/'src/lib.rs'; original=lib.read_text(); marker='    fn saved_queue_bytes(saved: &SavedQueue) -> Result<Vec<u8>> {'
    assert original.count(marker)==1
    instrumented=original.replace(marker,marker+'\n        #[cfg(test)] queue_transport_witness::SAVES.with(|s| s.set(s.get()+1));')
    # Existing test helper remains unchanged except visibility to sibling module.
    instrumented=instrumented.replace('    fn core() -> Core {','    pub(super) fn core() -> Core {')
    lib.write_text(instrumented+MODULE)
    env=dict(os.environ);env['CARGO_BUILD_JOBS']='2';env['CARGO_TARGET_DIR']=str(output/'target')
    print('WITNESS_INPUT',json.dumps({'sourceSha256':hashlib.sha256(original.encode()).hexdigest(),'testSha256':hashlib.sha256(MODULE.encode()).hexdigest(),'instrumentedSha256':hashlib.sha256(lib.read_bytes()).hexdigest()}),flush=True)
    cargo=Path(os.environ['SOUNDQ_RUST_BIN'])/'cargo'
    result=subprocess.run([str(cargo),'test','--locked','--offline','--manifest-path',str(output/'Cargo.toml'),'queue_transport_witness','--','--nocapture','--test-threads=1'],env=env)
    raise SystemExit(result.returncode)

if __name__=='__main__': main()
