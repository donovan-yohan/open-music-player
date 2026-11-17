package com.soundq.android.data.discovery
import com.soundq.android.data.*
import com.soundq.android.data.imports.*
class Selection(val id:String)
class Candidate(val downloadable:Boolean=true,val source:ImportSource)
class SourceChoice(val scope:AccountScope,val candidate:Candidate,val selection:Selection) {var consumed=false;fun valid()=true}
class SourceDecision(val id:String,val sessionId:String,val candidateId:String,val job:ImportJobId?)
enum class SourceImportPhase {SavingDecision,Queueing,DecisionRefused,DecisionUncertain,QueueRefused,QueueUncertain,ReadbackFailed,Accepted}
data class SourceImportReceipt(val choice:SourceChoice,val decision:SourceDecision?=null,val phase:SourceImportPhase=SourceImportPhase.SavingDecision)
