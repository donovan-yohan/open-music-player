package com.soundq.android.data
import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.*
/** Generated from exact root callback bodies. Unrelated shell/playlist effects are inert. */
internal class ExtractedDiscoveryRootActions(discovery:DiscoveryRepository,val discoveryView:DiscoveryView,imports:ImportRepository,val discoveryIntake:ImportView) {
 class Graph(val discovery:DiscoveryRepository,val imports:ImportRepository)
 class Model(val graph:Graph) {fun closePlaylistDetail(){}}
 class Closeable {fun close(){}}
 enum class HomeDestination {Home,History,Library}
 class Shell {fun navigate(next:HomeDestination){}}
 val model=Model(Graph(discovery,imports));val shell=Shell()
 var panel:String?=null;var picker:Closeable?=null;var trackCapture:Any?=null
 var playlistActions:Closeable?=null;var destination="Discover";var importView:ImportView?=null;var discoveryVisit=0L
 fun leaveDiscovery(){
        discoveryView?.let(model.graph.discovery::close)
        discoveryIntake?.let(model.graph.imports::close)
        discoveryVisit++
    }
 fun navigate(next:String){
        leaveDiscovery()
        panel=null;picker?.close();picker=null;trackCapture=null
        importView?.let(model.graph.imports::close);importView=null
        if(next!="Playlists"){model.closePlaylistDetail();playlistActions?.close()}
        shell.navigate(when(next){"Home"->HomeDestination.Home;"History"->HomeDestination.History;else->HomeDestination.Library})
        destination=next
    }
 fun openImports(){leaveDiscovery();panel=null;importView=model.graph.imports.open()}
 fun disposeChild(){model.graph.discovery.close(discoveryView);model.graph.imports.close(discoveryIntake)}
}
