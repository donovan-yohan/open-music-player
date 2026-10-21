#include "soundq_mix.h"
#include <stddef.h>
#include <stdio.h>
int main(void) {
  sq_config config={SQ_ABI_VERSION,48000,16,16};
  sq_engine *engine=sq_create(&config);
  if(!engine) return 1;
  const float pcm[]={.25f,-.5f,.5f,-.25f};
  sq_plan plan={0}; plan.revision=1; plan.deck_count=1; plan.master_gain=.5f;
  sq_deck *d=&plan.decks[0]; d->slot=3; d->instance_id=77; d->end_frame=2;
  d->pcm.sample_rate=48000; d->pcm.frame_count=2; d->pcm.bus_count=1; d->pcm.buses[0]=pcm;
  d->buses[0].gain=1;
  float out[4]={0};
  if(sq_submit(engine,&plan)!=SQ_OK || sq_render(engine,out,2)!=SQ_OK ||
     out[0]!=.125f || out[1]!=-.25f || out[2]!=.25f || out[3]!=-.125f ||
     sq_applied_revision(engine)!=1 || sq_rendered_frames(engine)!=2) return 2;
  sq_schedule_clip clip={0}; clip.instance_id=88; clip.asset_id=9;
  clip.start_frame=5; clip.end_frame=7; clip.source_frame_count=2;
  clip.bus_count=1; clip.buses[0].gain=1;
  sq_pcm_window window={0}; window.asset_id=9; window.pcm=d->pcm;
  sq_schedule_desc desc={0}; desc.revision=2; desc.master_gain=.5f;
  desc.clip_count=1; desc.clips=&clip; desc.window_count=1; desc.windows=&window;
  sq_schedule *schedule=NULL;
  if(sq_schedule_create(engine,&desc,&schedule)!=SQ_OK ||
     sq_schedule_submit(engine,schedule)!=SQ_OK ||
     sq_schedule_retire(schedule)!=SQ_BUSY) return 3;
  float scheduled[10]={0};
  if(sq_render(engine,scheduled,5)!=SQ_OK || scheduled[6]!=.125f ||
     scheduled[7]!=-.25f || scheduled[8]!=.25f || scheduled[9]!=-.125f ||
     sq_applied_revision(engine)!=2 || sq_missing_pcm_frames(engine)!=0) return 4;
  sq_destroy(engine);
  if(sq_schedule_get_state(schedule)!=SQ_SCHEDULE_COMPLETE || sq_schedule_retire(schedule)!=SQ_OK) return 5;
  printf("PASS C caller linked exported ABI v%u; config=%zu pcm=%zu bus=%zu deck=%zu plan=%zu plan.decks.offset=%zu\n",
         SQ_ABI_VERSION,sizeof(sq_config),sizeof(sq_pcm),sizeof(sq_bus_control),sizeof(sq_deck),sizeof(sq_plan),offsetof(sq_plan,decks));
  printf("schedule_clip=%zu pcm_window=%zu schedule_desc=%zu clip.buses.offset=%zu desc.clips.offset=%zu desc.windows.offset=%zu\n",
         sizeof(sq_schedule_clip),sizeof(sq_pcm_window),sizeof(sq_schedule_desc),offsetof(sq_schedule_clip,buses),offsetof(sq_schedule_desc,clips),offsetof(sq_schedule_desc,windows));
  return 0;
}
