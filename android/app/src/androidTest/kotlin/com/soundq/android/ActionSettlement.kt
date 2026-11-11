package com.soundq.android

import kotlinx.coroutines.Job

/** Invoke on the action's admission thread; join returned work off that thread. */
internal fun admittedActionJobs(parent:Job,action:()->Unit):List<Job> {
    val before=parent.children.toSet()
    action()
    return parent.children.filter {it !in before}.toList()
}
