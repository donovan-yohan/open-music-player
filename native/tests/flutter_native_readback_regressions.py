#!/usr/bin/env python3
"""Window-free synthetic boundary controls for the real owned-player sampler.

Compiles the production Objective-C method with faithful recording AVPlayer,
item/source and Flutter-result facades. Never creates a real player or audio.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
HEADER = r'''#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#include <mach/mach_time.h>
#include <limits.h>
#include <math.h>
#include <TargetConditionals.h>
typedef NS_ENUM(NSInteger, AVPlayerStatus) {AVPlayerStatusUnknown, AVPlayerStatusReadyToPlay, AVPlayerStatusFailed};
typedef NS_ENUM(NSInteger, AVPlayerItemStatus) {AVPlayerItemStatusUnknown, AVPlayerItemStatusReadyToPlay, AVPlayerItemStatusFailed};
typedef NS_ENUM(NSInteger, AVPlayerTimeControlStatus) {AVPlayerTimeControlStatusPaused, AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate, AVPlayerTimeControlStatusPlaying};
@interface FlutterError:NSObject
@property NSString *code;
+ (instancetype)errorWithCode:(NSString *)code message:(id)message details:(id)details;
@end
@implementation FlutterError
+ (instancetype)errorWithCode:(NSString *)code message:(id)message details:(id)details {FlutterError *e=[self new];e.code=code;return e;}
@end
typedef void (^FlutterResult)(id);
@interface AVPlayerItem:NSObject
@property CMTime currentTime;
@property AVPlayerItemStatus status;
@property NSError *error;
@end
@implementation AVPlayerItem @end
@interface AVQueuePlayer:NSObject
@property AVPlayerItem *currentItem;
@property CMTime currentTime;
@property float rate;
@property AVPlayerTimeControlStatus timeControlStatus;
@property AVPlayerStatus status;
@property NSError *error;
@end
@implementation AVQueuePlayer @end
@interface IndexedAudioSource:NSObject
@property NSString *sourceId;
@property AVPlayerItem *playerItem;
@property AVPlayerItem *playerItem2;
@end
@implementation IndexedAudioSource @end
@interface AudioPlayer:NSObject {
@public
 NSString *_playerId;
 AVQueuePlayer *_player;
 NSMutableArray<IndexedAudioSource *> *_indexedAudioSources;
 int _index;
 __weak AVQueuePlayer *_soundqObservedPlayer;
 __weak AVPlayerItem *_soundqObservedItem;
 unsigned long long _soundqPlayerGeneration;
 unsigned long long _soundqItemGeneration;
}
- (void)soundqNativeReadback:(id)arguments result:(FlutterResult)result;
@end
@implementation AudioPlayer
'''
CASES = r'''
@end
static void check(BOOL ok,NSString *message) {if(!ok){fprintf(stderr,"FAIL %s\n",message.UTF8String);exit(1);}}
static id sample(AudioPlayer *p,id argument) {__block id value;if(p){[p soundqNativeReadback:argument result:^(id v){check(value==nil,@"multiple-results");value=v;}];}check(value!=nil,@"missing-result");return value;}
int main(int argc,const char **argv) {@autoreleasepool {
 NSString *kind=argc>1 ? [NSString stringWithUTF8String:argv[1]] : @"positive";
 NSString *token=NSProcessInfo.processInfo.environment[@"SOUNDQ_NATIVE_PLAYER_READBACK_TOKEN"];
 AudioPlayer *p=[AudioPlayer new];p->_playerId=@"00000000-0000-4000-8000-000000000001";
 AVQueuePlayer *player=[AVQueuePlayer new];AVPlayerItem *item=[AVPlayerItem new];
 player.currentItem=item;player.currentTime=CMTimeMake(6000,1000);item.currentTime=CMTimeMake(6000,1000);
 player.rate=1;player.status=AVPlayerStatusReadyToPlay;item.status=AVPlayerItemStatusReadyToPlay;player.timeControlStatus=AVPlayerTimeControlStatusPlaying;
 IndexedAudioSource *source=[IndexedAudioSource new];source.sourceId=@"00000000-0000-4000-8000-000000000002";source.playerItem=item;
 p->_player=player;p->_indexedAudioSources=[NSMutableArray arrayWithObject:source];p->_index=0;
 id arg=@{@"capability":token ?: @""};
 if([kind isEqual:@"wrong-token"])arg=@{@"capability":[@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0]};
 if([kind isEqual:@"bad-token"])arg=@{@"capability":@"invalid"};
 if([kind isEqual:@"extra-field"])arg=@{@"capability":token ?: @"",@"extra":@1};
 if([kind isEqual:@"not-map"])arg=@"not-map";
 if([kind isEqual:@"no-player"])p->_player=nil;
 if([kind isEqual:@"no-item"])player.currentItem=nil;
 if([kind isEqual:@"bad-id"])p->_playerId=@"private-label";
 if([kind isEqual:@"bad-source"])source.sourceId=@"private-url";
 if([kind isEqual:@"bad-index"])p->_index=1;
 if([kind isEqual:@"wrong-item"])source.playerItem=[AVPlayerItem new];
 if([kind isEqual:@"invalid-time"])player.currentTime=kCMTimeInvalid;
 if([kind isEqual:@"epoch"])player.currentTime=(CMTime){.value=1,.timescale=1,.flags=kCMTimeFlags_Valid,.epoch=1};
 if([kind isEqual:@"infinite-rate"])player.rate=INFINITY;
 if([kind isEqual:@"generation-overflow"])p->_soundqItemGeneration=LLONG_MAX;
 id value=sample(p,arg);
 BOOL success=[value isKindOfClass:NSDictionary.class];
 BOOL expectSuccess=[@[@"positive",@"stable-generation",@"replacement",@"weak-retirement",@"error-flag"] containsObject:kind];
 check(success==expectSuccess,@"success-classification");
 if(success){
  NSDictionary *v=value;check([v[@"schema"] isEqual:@"soundq.just-audio.native-readback.v1"],@"schema");
  check([v[@"platform_id"] isEqual:p->_playerId] && [v[@"source_id"] isEqual:source.sourceId],@"owner-source");
  check([v[@"before_ticks"] unsignedLongLongValue]>0 && [v[@"after_ticks"] unsignedLongLongValue]>=[v[@"before_ticks"] unsignedLongLongValue],@"clock-bracket");
  check([v[@"position_value"] intValue]==6000 && [v[@"position_timescale"] intValue]==1000,@"raw-cursor");
  check(v.count==25 && !v[@"capability"] && !v[@"url"],@"safe-payload");
  if([kind isEqual:@"stable-generation"]){NSDictionary *next=sample(p,arg);check([next[@"player_witness"] isEqual:v[@"player_witness"]] && [next[@"item_witness"] isEqual:v[@"item_witness"]],@"stable-generations");}
  if([kind isEqual:@"replacement"]){AVPlayerItem *next=[AVPlayerItem new];next.currentTime=item.currentTime;next.status=item.status;source.playerItem=next;player.currentItem=next;NSDictionary *r=sample(p,arg);check([r[@"item_witness"] unsignedLongLongValue]==[v[@"item_witness"] unsignedLongLongValue]+1,@"replacement-generation");}
  if([kind isEqual:@"weak-retirement"]){__weak AVPlayerItem *weak=item;source.playerItem=nil;player.currentItem=nil;item=nil;check(weak==nil && p->_soundqObservedItem==nil,@"no-retained-item");}
  if([kind isEqual:@"error-flag"]){item.error=[NSError errorWithDomain:@"private-domain" code:1 userInfo:nil];NSDictionary *r=sample(p,arg);check([r[@"error_present"] boolValue] && r.count==25,@"error-presence-only");}
 }else check([value isKindOfClass:FlutterError.class] && [((FlutterError *)value).code hasPrefix:@"native-readback-"],@"safe-error");
 printf("PASS %s\n",kind.UTF8String);return 0;
}}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    path = args.source_root / 'client/third_party/just_audio/darwin/just_audio/Sources/just_audio/AudioPlayer.m'
    text = path.read_text()
    start = text.index('- (void)soundqNativeReadback:')
    end = text.index('\n- (void)dispose:', start)
    method = text[start:end]
    probe = args.output / 'sampler.m'
    probe.write_text(HEADER + method + CASES)
    receipt: dict[str, Any] = dict(scope='synthetic boundary facade; no real audio/player/window',
                   production_method_sha256=hashlib.sha256(method.encode()).hexdigest(),
                   source_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                   probe_sha256=hashlib.sha256(probe.read_bytes()).hexdigest(),
                   prepared=True, executed=False, cases=[])
    if not args.prepare_only:
        argv = ['clang', '-fobjc-arc', '-fblocks', '-x', 'objective-c', str(probe), '-framework', 'Foundation', '-framework', 'CoreMedia', '-o', str(args.output / 'probe')]
        r = subprocess.run(argv, capture_output=True, timeout=100)
        (args.output / 'compile.log').write_bytes(r.stdout + r.stderr)
        receipt['compile_exit'] = r.returncode
        receipt['executed'] = True
        if r.returncode == 0:
            token = secrets.token_hex(32)
            kinds = ['positive','stable-generation','replacement','weak-retirement','error-flag','wrong-token','bad-token','extra-field','not-map','no-player','no-item','bad-id','bad-source','bad-index','wrong-item','invalid-time','epoch','infinite-rate','generation-overflow','disabled','missing-token']
            for kind in kinds:
                env = dict(os.environ, SOUNDQ_NATIVE_PLAYER_READBACK='1', SOUNDQ_NATIVE_PLAYER_READBACK_TOKEN=token)
                if kind == 'disabled':env.pop('SOUNDQ_NATIVE_PLAYER_READBACK')
                if kind == 'missing-token':env.pop('SOUNDQ_NATIVE_PLAYER_READBACK_TOKEN')
                r = subprocess.run([str(args.output / 'probe'), kind], env=env, capture_output=True, timeout=10)
                (args.output / (kind + '.log')).write_bytes(r.stdout + r.stderr)
                receipt['cases'].append(dict(name=kind, exit=r.returncode))
    (args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    passed = args.prepare_only or receipt.get('compile_exit') == 0 and all(r['exit'] == 0 for r in receipt['cases'])
    print(json.dumps(dict(output=str(args.output), executed=receipt['executed'], passed=passed)))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
