package com.soundq.android.playback.system

/** OS verification, not a caller-supplied package allowlist or connection hint. */
internal fun systemControllerAllowed(sameUid:Boolean,trusted:Boolean,packageVerified:Boolean)=sameUid || (trusted && packageVerified)
