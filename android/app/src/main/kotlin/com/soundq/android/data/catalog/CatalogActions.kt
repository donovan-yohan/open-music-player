package com.soundq.android.data.catalog

/** Claim synchronously on the mounted caller, before handing work to IO. */
class CatalogActions(private val repository:CatalogRepository,private val enqueue:((()->Unit)->Unit)):AutoCloseable {
    val view=repository.open()
    private fun send(request:CatalogRequest?) {request?.let {enqueue {repository.load(it)}}}
    fun edit(text:String) {view?.let {repository.edit(it,text)}}
    fun search(albums:Boolean=false,offset:Int=0) {view?.let {send(if(albums)repository.releases(it,offset) else repository.search(it,offset))}}
    fun submit(text:String,albums:Boolean=false) {view?.let {repository.edit(it,text);send(if(albums)repository.releases(it) else repository.search(it))}}
    fun artist(source:CatalogState,row:CatalogArtistRow) {view?.let {send(repository.artist(it,source,row))}}
    fun album(source:CatalogState,row:CatalogAlbumRow) {view?.let {send(repository.album(it,source,row))}}
    fun group(source:CatalogState,row:CatalogReleaseGroup) {view?.let {repository.group(it,source,row)}}
    fun discover(details:com.soundq.android.data.discovery.DiscoveryDetails):Boolean {
        val mounted=view ?: return false
        if(!repository.discover(mounted,details))return false
        send(repository.discoveredRead(mounted));return true
    }
    fun groupEditions(source:CatalogState) {view?.let {send(repository.groupEditions(it,source))}}
    fun retry(source:CatalogState) {view?.let {send(repository.retry(it,source))}}
    fun recording(source:CatalogState,row:CatalogRecording,index:Int) {view?.let {repository.recording(it,source,row,index)?.let {request->enqueue {repository.loadResolution(request)}}}}
    fun retryRecording(source:CatalogInspection) {view?.let {repository.retryRecording(it,source)?.let {request->enqueue {repository.loadResolution(request)}}}}
    fun dismissRecording(source:CatalogInspection) {view?.let {repository.dismissRecording(it,source)}}
    fun addRecording(source:CatalogInspection) {view?.let {repository.addRecording(it,source)?.let {request->enqueue {repository.executeMembership(request)}}}}
    fun checkMembership(source:CatalogMembershipRecovery) {view?.let {repository.checkMembership(it,source)?.let {request->enqueue {repository.executeMembership(request)}}}}
    fun retryMembership(source:CatalogMembershipRecovery) {view?.let {repository.checkMembership(it,source,true)?.let {request->enqueue {repository.executeMembership(request)}}}}
    fun back():Boolean=view?.let(repository::back) ?: false
    override fun close() {view?.let(repository::close)}
}
