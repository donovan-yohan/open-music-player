package com.soundq.android.playback.listening
import org.junit.runner.JUnitCore
import org.junit.runner.Description
import org.junit.runner.notification.Failure
import org.junit.runner.notification.RunListener
object NamedTestRunner {
 @JvmStatic fun main(args:Array<String>) {
  val failed=mutableSetOf<String>()
  val core=JUnitCore()
  core.addListener(object:RunListener(){
   override fun testFailure(failure:Failure){failed.add(failure.description.methodName);System.err.println(failure.trace)}
   override fun testFinished(description:Description){println("CASE " + description.className + "#" + description.methodName + " " + if(description.methodName in failed)"FAIL" else "PASS")}
  })
  val result=if(System.getProperty("soundq.close.only")=="true")core.run(RollingAcquisitionCloseTest::class.java)
   else core.run(PreparedListeningHostTest::class.java, RollingListeningHostTest::class.java, RollingAcquisitionCloseTest::class.java)
  println("RESULT tests="+result.runCount+" failures="+result.failureCount+" ignored="+result.ignoreCount)
  if(!result.wasSuccessful())kotlin.system.exitProcess(1)
 }
}
