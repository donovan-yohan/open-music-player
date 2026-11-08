package com.soundq.android.data.discovery

import com.soundq.android.data.SoundQApi
import okhttp3.*
import java.util.concurrent.TimeUnit

/** One mounted source-art read, never an authenticated API or persistent media cache. */
internal class SourceArtworkRead(client:OkHttpClient):AutoCloseable {
    companion object {const val MAX_BYTES=4_000_000}
    private class Owner(val valid:()->Boolean)
    private var closed=false
    private var call:Call?=null
    private val client=client.newBuilder().apply {
        interceptors().clear();networkInterceptors().clear()
        authenticator(Authenticator.NONE);proxyAuthenticator(Authenticator.NONE)
        cookieJar(CookieJar.NO_COOKIES);cache(null);eventListener(EventListener.NONE)
        followRedirects(false);followSslRedirects(false);retryOnConnectionFailure(false)
        callTimeout(15,TimeUnit.SECONDS)
        addNetworkInterceptor {chain->
            if(!current()||chain.request().tag(Owner::class.java)?.valid?.invoke()!=true||chain.request().header("Authorization")!=null||chain.request().header("Cookie")!=null)throw java.io.IOException("Retired artwork")
            chain.proceed(chain.request())
        }
    }.build()
    @Synchronized private fun current()=!closed
    fun load(url:String,valid:()->Boolean):ByteArray? {
        if(!SoundQApi.safeMediaUrl(url)||!valid())return null
        val work=synchronized(this) {
            if(closed||call!=null)return null
            client.newCall(Request.Builder().url(url).tag(Owner::class.java,Owner(valid)).build()).also {call=it}
        }
        return try {
            if(!valid())return null
            work.execute().use {response->
                if(response.code!=200||response.body.contentLength()>MAX_BYTES||!current()||!valid())return null
                val source=response.body.source()
                if(source.request(MAX_BYTES.toLong()+1)||!current()||!valid())return null
                source.readByteArray().takeIf {it.size<=MAX_BYTES&&current()&&valid()}
            }
        } catch(_:Exception){null}
        finally {synchronized(this){if(call===work)call=null}}
    }
    @Synchronized override fun close() {closed=true;call?.cancel();call=null}
}
