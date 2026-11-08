package com.soundq.android

/** Generated analysis BPM only. No authored beat position or manual override. */
class WaveformBpmFixtureRunner : ProductFixtureRunner() {
    override val fixtureApplicationClass get()=WaveformBpmFixtureApplication::class.java.name
}
class WaveformBpmFixtureApplication : TempoTransitionFixtureApplication() {
    override val sourceAnalysis:Map<Long,String> = (1L..2L).associateWith {TempoTransitionFixtureApplication.analysis(it,authored=false)}
}

/** Separate invocation, so missing-BPM setup never changes the ordinary generated-BPM scenario. */
class MissingWaveformBpmFixtureRunner : ProductFixtureRunner() {
    override val fixtureApplicationClass get()=MissingWaveformBpmFixtureApplication::class.java.name
}
class MissingWaveformBpmFixtureApplication : TempoTransitionFixtureApplication() {
    override val sourceAnalysis:MutableMap<Long,String> = (1L..2L).associateWith {TempoTransitionFixtureApplication.analysis(it,authored=false)}.toMutableMap()
    override fun prepareGraph(graph:AppGraph) {
        super.prepareGraph(graph)
        // The inherited dispatcher reads this map at request time. Remove generated BPM before any read.
        sourceAnalysis.replaceAll {_,raw->org.json.JSONObject(raw).apply {getJSONObject("summary").remove("bpm")}.toString()}
    }
}
