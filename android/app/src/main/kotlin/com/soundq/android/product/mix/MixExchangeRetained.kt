package com.soundq.android.product.mix

import com.soundq.android.data.AccountScope
import com.soundq.android.data.SoundQApi
import com.soundq.android.data.mix.*

/** ViewModel-owned, memory-only account draft. Route removal never proves a write rolled back. */
internal class MixExchangeRetained(private val api:SoundQApi) {
    private var account:AccountScope?=null
    private var owner:MixExchangeOwner?=null

    @Synchronized fun open(scope:AccountScope):MixExchangeRoute? {
        retireObsolete()
        if(!api.session.remoteCurrent(scope))return null
        if(owner==null) {account=scope;owner=MixExchangeOwner(api,scope)}
        return MixExchangeRoute(owner!!)
    }
    @Synchronized fun retireObsolete() {
        if(account?.let(api.session::remoteCurrent)!=true)retire()
    }
    @Synchronized fun retire() {owner?.retire();owner=null;account=null}
}

/** A route/selection capability, distinct from verified transport acceptance. Never keyed by ID alone. */
internal class MixExchangeRoute(val owner:MixExchangeOwner) {
    class Capture internal constructor(internal val generation:Long,val binding:MixExchangeOwner.Binding)
    private var generation=0L
    private var active=true
    private var binding=owner.bind(null)
    @Synchronized fun capture()=Capture(generation,binding)
    @Synchronized fun current(c:Capture)=active&&c.generation==generation&&c.binding===binding&&binding.snapshot().phase!=ExchangePhase.Retired
    @Synchronized fun select(c:Capture,saved:SavedMix?):Boolean {
        if(!current(c))return false
        generation++;binding.close();binding=owner.bind(saved)
        return true
    }
    @Synchronized fun close() {if(active){active=false;generation++;binding.close()}}
}
