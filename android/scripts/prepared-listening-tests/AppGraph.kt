package com.soundq.android
class AppGraph(val directory:java.io.File,val inputs:Map<String,java.io.File>) { val applicationContext=android.content.Context();var closes=0;val opens=mutableListOf<String>();var announced:Long?=null;var extraBytes=0;var closeFailure=false;var oneShotCloseFailure:Throwable?=null;var closeAttempts=0;var closeNoops=0;val closeFailures=mutableListOf<Throwable>() }
