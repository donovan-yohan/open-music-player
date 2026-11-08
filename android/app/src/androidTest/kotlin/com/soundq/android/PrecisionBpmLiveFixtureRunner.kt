package com.soundq.android

/** Long real encoded input for the ordinary on-air editor journey, not longer assertions. */
class PrecisionBpmLiveFixtureRunner : ProductFixtureRunner() {
    override val fixtureApplicationClass get()=PrecisionBpmLiveFixtureApplication::class.java.name
    override fun newApplication(cl:ClassLoader,className:String,context:android.content.Context):android.app.Application {
        ProductTransportFixture.audioDurationMs=120000
        return super.newApplication(cl,className,context)
    }
}
class PrecisionBpmLiveFixtureApplication : TempoTransitionFixtureApplication() {
    override val durationMs=120000L
    override val sourceAnalysis:Map<Long,String> = (1L..2L).associateWith {
        TempoTransitionFixtureApplication.analysis(it,authored=false,durationMs=durationMs)
    }
}
