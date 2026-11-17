package com.soundq.android.data.discovery

import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.InetAddress
import java.net.Proxy
import java.net.URI
import java.util.concurrent.TimeUnit

/** Typed CAA-only public reader. Generic source thumbnails still refuse every redirect. */
internal class CaaArtworkRead(
    mediaClient:OkHttpClient,
    // Internal fixture seam: production uses the strict public-address predicate, never a URL override.
    private val addressAllowed:(InetAddress)->Boolean=::publicAddress,
    private val budgetNanos:Long=DEADLINE_NANOS,
):AutoCloseable {
    companion object {
        const val MAX_REDIRECTS=4
        const val MAX_REDIRECT_BYTES=65_536L
        const val DEADLINE_NANOS=15_000_000_000L
        internal fun trustedUrl(raw:String):HttpUrl? {
            if(raw.length>4096)return null
            val uri=runCatching {URI(raw)}.getOrNull() ?: return null
            if(uri.scheme!="https"||uri.rawUserInfo!=null||uri.port !in setOf(-1,443)||uri.rawFragment!=null)return null
            val url=raw.toHttpUrlOrNull() ?: return null
            val host=url.host
            return url.takeIf {host=="coverartarchive.org"||host=="archive.org"||
                host.endsWith(".archive.org")&&host.split('.').all {Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?").matches(it)}}
        }
        internal fun publicAddress(ip:InetAddress):Boolean {
            if(ip.isAnyLocalAddress||ip.isLoopbackAddress||ip.isLinkLocalAddress||ip.isSiteLocalAddress||ip.isMulticastAddress)return false
            val b=ip.address.map {it.toInt() and 255}
            if(b.size==4) {
                val a=b[0];val c=b[1];val d=b[2]
                return !(a==0||a==10||a==127||a>=224||a==100&&c in 64..127||a==169&&c==254||
                    a==172&&c in 16..31||a==192&&(c==168||c==0||c==2||c==88&&d==99)||
                    a==198&&(c in 18..19||c==51&&d==100)||a==203&&c==0&&d==113)
            }
            // Global unicast only; refuse transition/documentation/special-use space as well.
            return b.size==16&&(b[0] and 0xe0)==0x20&&!(b[0]==0x20&&b[1]==0x01&&(b[2]<2||b[2]==0x0d&&b[3]==0xb8))&&!(b[0]==0x20&&b[1]==0x02)&&!(b[0]==0x3f&&(b[1] and 0xf0)==0xf0)
        }
    }
    private class Owner(val valid:()->Boolean)
    private var closed=false
    private var call:Call?=null
    private var loading=false
    @Synchronized private fun current()=!closed
    private val publicClient=mediaClient.newBuilder().apply {
        interceptors().clear();networkInterceptors().clear()
        authenticator(Authenticator.NONE);proxyAuthenticator(Authenticator.NONE)
        cookieJar(CookieJar.NO_COOKIES);cache(null);eventListener(EventListener.NONE)
        followRedirects(false);followSslRedirects(false);retryOnConnectionFailure(false)
        // No inherited proxy, pooled connection/coalescing or URL-observing listener.
        proxy(Proxy.NO_PROXY);connectionPool(ConnectionPool());protocols(listOf(Protocol.HTTP_1_1))
        dns {host->
            if(trustedUrl("https://$host/")==null)throw java.net.UnknownHostException("Refused artwork origin")
            mediaClient.dns.lookup(host).also {addresses->
                if(!current()||addresses.isEmpty()||addresses.any {!addressAllowed(it)})throw java.net.UnknownHostException("Refused artwork address")
            }
        }
        addNetworkInterceptor {chain->
            val request=chain.request();val owner=request.tag(Owner::class.java)
            val remote=(chain.connection()?.socket()?.remoteSocketAddress as? java.net.InetSocketAddress)?.address
            if(!current()||owner?.valid?.invoke()!=true||trustedUrl(request.url.toString())==null||remote==null||!addressAllowed(remote)||
                listOf("Authorization","Proxy-Authorization","Cookie","Referer").any {request.header(it)!=null})throw java.io.IOException("Refused artwork")
            chain.proceed(request)
        }
    }.build()
    fun load(ref:CaaArtworkRef,valid:()->Boolean):ByteArray? {
        if(!valid())return null
        synchronized(this){if(closed||loading)return null;loading=true}
        val end=System.nanoTime()+budgetNanos.coerceIn(1,DEADLINE_NANOS)
        fun eligible()=current()&&System.nanoTime()<end&&valid()
        return try {
            var url=trustedUrl(ref.entryUrl) ?: return null
            val visited=mutableSetOf<String>();var consumed=0L
            for(hop in 0..MAX_REDIRECTS) {
                if(!eligible()||!visited.add(url.toString()))return null
                val work=publicClient.newCall(Request.Builder().url(url).tag(Owner::class.java,Owner(::eligible)).build())
                val remaining=end-System.nanoTime();if(remaining<=0)return null
                work.timeout().timeout(remaining,TimeUnit.NANOSECONDS)
                if(!eligible())return null
                synchronized(this){if(closed)return null;call=work}
                var next:HttpUrl?=null
                work.execute().use {response->
                    if(!eligible())return null
                    val redirect=response.code in setOf(301,302,303,307,308)
                    if(!redirect&&response.code!=200)return null
                    val cap=minOf(SourceArtworkRead.MAX_BYTES-consumed,if(redirect)MAX_REDIRECT_BYTES else SourceArtworkRead.MAX_BYTES.toLong())
                    if(cap<0||response.body.contentLength()>cap)return null
                    val source=response.body.source()
                    if(source.request(cap+1)||!eligible())return null
                    val bytes=source.readByteArray();consumed+=bytes.size
                    if(bytes.size>cap||!eligible())return null
                    if(!redirect)return bytes
                    if(hop==MAX_REDIRECTS)return null
                    val location=response.headers.values("Location").singleOrNull() ?: return null
                    if(location.length>4096)return null
                    val resolved=runCatching {URI(url.toString()).resolve(location).toString()}.getOrNull() ?: return null
                    next=trustedUrl(resolved) ?: return null
                }
                synchronized(this){if(call===work)call=null}
                url=next ?: return null
            }
            null
        }catch(_:Exception){null}
        finally {synchronized(this){call=null;loading=false};publicClient.connectionPool.evictAll()}
    }
    @Synchronized override fun close(){closed=true;call?.cancel()}
}
