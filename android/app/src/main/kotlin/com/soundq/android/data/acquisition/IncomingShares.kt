package com.soundq.android.data.acquisition

import com.soundq.android.data.*
import com.soundq.android.data.imports.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File

class SharedLink(val source:ImportSource,val account:String?) {override fun toString()="SharedLink([redacted])"}
/** OS share admission only. Authentication never grants automatic submission. */
class IncomingShares(private val file:File?=null) {
    private val mutable=MutableStateFlow<SharedLink?>(null)
    val state:StateFlow<SharedLink?> = mutable
    init {runCatching {if(file?.isFile==true&&file.length()<=8192){val parts=file.readLines();val source=ImportSource.parse(parts.last()) ?: error("source");mutable.value=SharedLink(source,parts.first().takeIf {it.isNotEmpty()})}}}
    @Synchronized fun receive(text:String,account:String?):Boolean {
        if(text.toByteArray().size>8192)return false
        val urls=Regex("https://[^\\s<>]+",RegexOption.IGNORE_CASE).findAll(text).mapNotNull {ImportSource.parse(it.value.trimEnd('.',',',')',']',';'))}.toList()
        if(urls.size!=1)return false
        val link=SharedLink(urls.single(),account)
        try {file?.apply {parentFile?.mkdirs();writeText((account ?: "")+"\n"+link.source.url)}}catch(_:Exception){return false}
        mutable.value=link;return true
    }
    @Synchronized fun dismiss(expected:SharedLink) {if(mutable.value!==expected)return;file?.delete();mutable.value=null}
    fun visible(account:String?)=state.value?.takeIf {it.account==null||it.account==account}
}
