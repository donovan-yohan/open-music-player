package com.soundq.android.data

import java.io.File
import org.junit.runner.JUnitCore
import org.junit.runner.Description
import org.junit.runner.notification.Failure
import org.junit.runner.notification.RunListener
import kotlinx.serialization.json.*

/** Retain real JUnit terminal identities, including predecessor failures. */
object PlaylistSyncNamedRunner {
 @JvmStatic fun main(args:Array<String>) {
  val rows=mutableListOf<String>();val failed=mutableSetOf<String>()
  fun key(d:Description)="${d.className}#${d.methodName}"
  fun event(d:Description,status:String){rows+=buildJsonObject{put("test",key(d));put("status",status)}.toString();println("TEST_${status.uppercase()} ${key(d)}")}
  val core=JUnitCore();core.addListener(object:RunListener(){
   override fun testFailure(f:Failure){failed+=key(f.description);System.err.println(f.trace)}
   override fun testFinished(d:Description){event(d,if(key(d) in failed)"fail" else "pass")}
   override fun testIgnored(d:Description){event(d,"skip")}
  })
  val result=core.run(*args.map{Class.forName(it)}.toTypedArray())
  File(System.getProperty("soundq.tests.events")).writeText(rows.joinToString("\n",postfix="\n"))
  println("Tests run: ${result.runCount}, failures: ${result.failureCount}, ignored: ${result.ignoreCount}")
  kotlin.system.exitProcess(if(result.wasSuccessful())0 else 1)
 }
}
