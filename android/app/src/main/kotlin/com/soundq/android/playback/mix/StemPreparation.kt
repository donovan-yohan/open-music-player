package com.soundq.android.playback.mix

import com.soundq.android.data.*
import com.soundq.android.data.mix.*
import okhttp3.*
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

/** Loader-owned, bounded private encoded members. No separation jobs, credentials or callback work. */
internal class StemPreparation(private val directory:File,private val api:SoundQApi,private val scope:AccountScope,client:OkHttpClient,private val current:()->Boolean,private val reserve:(Long)->Unit):AutoCloseable {
    private val files=mutableListOf<File>()
    private val downloaded=mutableMapOf<String,String>()
    private val http=client.newBuilder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
        .callTimeout(60,java.util.concurrent.TimeUnit.SECONDS)
        .addNetworkInterceptor {chain ->checkCurrent();require(chain.request().header("Authorization")==null);chain.proceed(chain.request())}.build()
    private fun checkCurrent(){check(current())}
    fun prepare(plan:SavedMix):Map<String,PreparedMixStems> {
        val prepared=mutableMapOf<String,PreparedMixStems>()
        for(clip in plan.clips) {
            val edits=clip.stems ?: continue
            checkCurrent()
            val publication=StemPublication.parse(api.mixStemStatus(scope,clip.track,MixJson.text(edits,"channelSet"),current),clip.track,edits)
            val rolePaths=publication.members.associate {member ->
                val identity=member.digest+":"+member.bytes
                val path=downloaded[identity] ?: run {
                    reserve(member.bytes);checkCurrent()
                    val file=Files.createTempFile(directory.toPath(),"mix-stem-",".opus").toFile();files+=file
                    http.newCall(Request.Builder().url(member.url).get().build()).execute().use {response ->
                        require(response.code==200)
                        val digest=MessageDigest.getInstance("SHA-256")
                        response.body.byteStream().use {input ->file.outputStream().use {output ->
                            val bytes=ByteArray(64*1024);var count=0L
                            while(true){checkCurrent();val n=input.read(bytes);if(n<0)break;count+=n;require(count<=member.bytes);digest.update(bytes,0,n);output.write(bytes,0,n)}
                            require(count==member.bytes)
                        }}
                        require(digest.digest().joinToString(""){b->"%02x".format(b)}==member.digest)
                    }
                    file.absolutePath.also {downloaded[identity]=it}
                }
                checkCurrent();NativeMix.probe(path,member.frames,member.preSkip)
                member.role to path
            }
            prepared[clip.id]=PreparedMixStems(publication.channels,publication.channels.map {rolePaths.getValue(it)})
        }
        checkCurrent();return prepared
    }
    override fun close(){files.forEach {it.delete()};files.clear();downloaded.clear()}
}
