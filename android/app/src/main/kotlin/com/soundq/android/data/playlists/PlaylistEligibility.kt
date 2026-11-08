package com.soundq.android.data.playlists

import com.soundq.android.data.MutationOutcome

/** Eligibility shared by mounted controls and their action boundary. */
fun PlaylistState.canCreate(draft: PlaylistDraft): Boolean = !loading && !draft.isPublic && mutation?.outcome != MutationOutcome.Pending &&
    (uncertainDraft == null || (reconciled && renewedDraft == draft && draft != uncertainDraft))
fun PlaylistState.canStartNew(draft: PlaylistDraft): Boolean = !loading && !draft.isPublic && mutation?.outcome == MutationOutcome.Uncertain && reconciled && draft != uncertainDraft && renewedDraft != draft
