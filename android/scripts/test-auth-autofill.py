#!/usr/bin/env python3
"""Execute actual auth caller and editor bodies against configuration-only boundaries.

This is not mounted Compose or Android autofill acceptance. Remember slots and
lifecycle callbacks are retained, so reveal/reset callbacks do not get fresh state.
"""
import argparse
from pathlib import Path

p=argparse.ArgumentParser()
p.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1])
p.add_argument('--generate',type=Path,required=True)
p.add_argument('--standalone',action='store_true')
a=p.parse_args()
def block(text,anchor):
    assert text.count(anchor)==1,(anchor,text.count(anchor))
    start=text.index(anchor);opening=text.index('{',start);depth=1;end=opening+1
    while depth:
        depth+=(text[end]=='{')-(text[end]=='}');end+=1
    return text[start:end]
app=(a.root/'app/src/main/kotlin/com/soundq/android/product/ProductApp.kt').read_text()
ds=(a.root/'designsystem/src/main/kotlin/com/soundq/designsystem/ProductComponents.kt').read_text()
auth=block(app,'@Composable private fun AuthScreen(').replace('@Composable private fun','fun')
for old,new in [('androidx.lifecycle.compose.LocalLifecycleOwner','LocalLifecycleOwner'),('androidx.compose.ui.focus.FocusDirection','FocusDirection')]:
    auth=auth.replace(old,new)
field=block(ds,'@Composable fun SoundQEntryField(').replace('@Composable ','')
prelude=r'''package com.soundq.android.authautofill
import kotlin.reflect.KProperty
ANNOTATION_IMPORT
annotation class Composable
class State<T>(var value:T) {operator fun getValue(o:Any?,p:KProperty<*>)=value;operator fun setValue(o:Any?,p:KProperty<*>,v:T){value=v}}
fun <T> mutableStateOf(v:T)=State(v)
object Memory {val slots=mutableListOf<Any?>();var cursor=0;val saved=mutableSetOf<Int>();fun clear(){slots.clear();cursor=0;saved.clear()}}
@Suppress("UNCHECKED_CAST") fun <T> remember(block:()->State<T>):State<T> {val i=Memory.cursor++;if(i==Memory.slots.size)Memory.slots.add(block());return Memory.slots[i] as State<T>}
fun <T> rememberSaveable(stateSaver:Any?=null,block:()->State<T>):State<T> {Memory.saved.add(Memory.cursor);return remember(block)}
data class TextRange(val start:Int,val end:Int=start)
data class TextFieldValue(val text:String,val selection:TextRange=TextRange(0),val composition:TextRange?=null) {companion object {val Saver=Any()}}
enum class ContentType {EmailAddress,Password,NewUsername,NewPassword}
open class Modifier(val properties:MutableMap<String,Any?> = mutableMapOf()) {companion object:Modifier()}
class Semantics {var contentDescription:String?=null;var contentType:ContentType?=null;fun heading(){}}
fun Modifier.semantics(body:Semantics.()->Unit):Modifier {val s=Semantics().apply(body);return Modifier(properties.toMutableMap().apply {put("label",s.contentDescription);put("role",s.contentType)})}
fun Modifier.fillMaxWidth()=this
fun Modifier.fillMaxSize()=this
fun Modifier.widthIn(max:Int)=this
fun Modifier.verticalScroll(s:Any)=this
fun Modifier.padding(s:Int)=this
fun Modifier.size(s:Int)=this
object Arrangement {fun spacedBy(i:Int)=i}
fun Column(modifier:Modifier,verticalArrangement:Int,body:()->Unit){body()}
object Alignment {val CenterVertically=0}
fun Row(verticalAlignment:Int=0,horizontalArrangement:Int=0,body:()->Unit){body()}
fun FlowRow(horizontalArrangement:Int=0,verticalArrangement:Int=0,body:()->Unit){body()}
fun Text(value:String,style:Int=0,color:Int=0,modifier:Modifier=Modifier){}
fun Image(p:Any?,description:String?,modifier:Modifier){}
fun painterResource(i:Int)=i
object R {object drawable {val soundq_logo=0}}
fun rememberScrollState()=0
object SoundQ {object typography {val caption=0;val body=0;val heading=0;val title=0};object spacing {val small=0;val gutter=0;val medium=0};object sizes {val appMax=0;val target=48};object colors {val focus=0;val inputBorder=0;val error=0;val muted=0}}
object RectangleShape
open class VisualTransformation {companion object {val None=VisualTransformation()}}
class PasswordVisualTransformation:VisualTransformation()
enum class KeyboardType {Email,Password}
enum class ImeAction {Next,Done}
class KeyboardOptions(val keyboardType:KeyboardType?=null,val imeAction:ImeAction?=null) {companion object {val Default=KeyboardOptions()}}
class KeyboardActions(val onDone:(()->Unit)?=null,val onNext:(()->Unit)?=null) {companion object {val Default=KeyboardActions()}}
enum class SoundQIcon {Eye,EyeOff}
enum class SoundQButtonVariant {Secondary,Quiet}
enum class FeedbackKind {Loading,Error}
object OutlinedTextFieldDefaults {fun colors(focusedBorderColor:Int,unfocusedBorderColor:Int,cursorColor:Int,errorBorderColor:Int)=0}
data class NativeField(val value:TextFieldValue,val edit:(TextFieldValue)->Unit,val modifier:Modifier,val enabled:Boolean,val transformation:VisualTransformation,val keys:KeyboardActions)
data class Action(val enabled:Boolean,val run:()->Unit)
val fields=linkedMapOf<String,NativeField>();val actions=linkedMapOf<String,Action>()
fun OutlinedTextField(value:TextFieldValue,onValueChange:(TextFieldValue)->Unit,modifier:Modifier,enabled:Boolean,singleLine:Boolean,textStyle:Int,shape:Any,isError:Boolean,visualTransformation:VisualTransformation,keyboardOptions:KeyboardOptions,keyboardActions:KeyboardActions,trailingIcon:(()->Unit)?,supportingText:(()->Unit)?,colors:Int) {fields[modifier.properties["label"] as String]=NativeField(value,onValueChange,modifier,enabled,visualTransformation,keyboardActions);trailingIcon?.invoke()}
fun SoundQIconButton(icon:SoundQIcon,label:String,run:()->Unit,enabled:Boolean){actions[label]=Action(enabled,run)}
fun SoundQButton(label:String,run:()->Unit,enabled:Boolean=true,variant:SoundQButtonVariant?=null){actions[label]=Action(enabled,run)}
fun SoundQFeedback(label:String,kind:FeedbackKind,detail:String?=null,action:String?=null,onAction:(()->Unit)?=null){}
fun SoundQSheet(title:String,onDismiss:()->Unit,body:()->Unit){body()}
object Focus {fun clearFocus(){};fun moveFocus(direction:FocusDirection){}}
object LocalFocusManager {val current=Focus}
enum class FocusDirection {Down}
class Lifecycle {enum class Event {ON_STOP};val observers=mutableListOf<LifecycleEventObserver>();fun addObserver(o:LifecycleEventObserver){observers.add(o)};fun removeObserver(o:LifecycleEventObserver){observers.remove(o)}}
fun interface LifecycleEventObserver {fun onStateChanged(owner:Any?,event:Lifecycle.Event)}
class Owner {val lifecycle=Lifecycle()}
object LocalLifecycleOwner {val current=Owner()}
val disposals=mutableListOf<()->Unit>()
class Disposal {fun onDispose(body:()->Unit){disposals.add(body)}}
fun DisposableEffect(key:Any,body:Disposal.()->Unit){if(disposals.isEmpty())Disposal().body()}
object SafeFailure {enum class Reason(val message:String) {StoreRejected("Rejected"),Network("Could not reach server"),Refused("Refused")}}
sealed interface AuthState {object Pending:AuthState;object Restoring:AuthState;class SignedOut(val error:SafeFailure.Reason?=null,val uncertain:Boolean=false):AuthState;class SaveRequired(val reason:SafeFailure.Reason):AuthState}
class Flow<T>(val value:T) {fun collectAsStateWithLifecycle()=State(value)}
class ProductViewModel {val graph=Graph();val onlineRestore=Flow<Any?>(null);val submissions=mutableListOf<Triple<String,String,String?>>()
fun submit(e:String,p:String,u:String?){submissions.add(Triple(e,p,u))};fun useDeviceDownloads(){};fun retrySave(){};fun cancelAuth(){};fun discardStore(){};fun restore(){};fun reconnectSaved(){}}
class Session {fun canListenOffline()=false;fun canReconnectSaved()=false}
class Graph {val endpoint=Endpoint();val session=Session()};class Endpoint {val identity="fixture.invalid"}
'''
tests=r'''
class AuthAutofillConfigurationTest {
 private lateinit var model:ProductViewModel
 private fun setup(){Memory.clear();disposals.clear();LocalLifecycleOwner.current.lifecycle.observers.clear();model=ProductViewModel();render()}
 private fun render(state:AuthState=AuthState.SignedOut()){Memory.cursor=0;fields.clear();actions.clear();AuthScreen(state,model)}
 private fun click(label:String){val a=actions[label]?:error("Missing action $label");check(a.enabled);a.run();render()}
 private fun role(label:String,expected:ContentType){check(fields.getValue(label).modifier.properties["role"]==expected){"Actual editor $label must expose $expected"}}
 private fun hidden(label:String)=fields.getValue(label).transformation is PasswordVisualTransformation
 private fun edit(label:String,value:TextFieldValue){fields.getValue(label).edit(value);render()}
 TEST fun loginRolesReachActualEditor(){setup();role("Email",ContentType.EmailAddress);role("Password",ContentType.Password);check("Username" !in fields);check("Confirm password" !in fields)}
 TEST fun registrationRolesReachActualEditors(){setup();click("Register");role("Email",ContentType.EmailAddress);role("Username",ContentType.NewUsername);role("Password",ContentType.NewPassword);role("Confirm password",ContentType.NewPassword)}
 TEST fun independentRevealPreservesNativeValueSelectionAndComposition(){setup();click("Register");val v=TextFieldValue("test-only",TextRange(2,5),TextRange(1,6));edit("Password",v);edit("Confirm password",v);click("Show Password");check(!hidden("Password"));check(hidden("Confirm password"));click("Show Confirm password");check(!hidden("Confirm password"));check(!hidden("Password"));click("Hide Password");check(hidden("Password"));check(!hidden("Confirm password"));check(fields.getValue("Password").value===v);check(fields.getValue("Confirm password").value===v);check(model.submissions.isEmpty())}
 TEST fun stopModeAndDisposalRetireUnsavedSecretsAndBothReveals(){setup();click("Register");edit("Password",TextFieldValue("test-only"));edit("Confirm password",TextFieldValue("test-only"));click("Show Password");click("Show Confirm password");LocalLifecycleOwner.current.lifecycle.observers.toList().forEach {it.onStateChanged(null,Lifecycle.Event.ON_STOP)};render();check(fields.getValue("Password").value.text.isEmpty());check(fields.getValue("Confirm password").value.text.isEmpty());check(hidden("Password")&&hidden("Confirm password"));click("Show Password");click("Show Confirm password");click("Use an existing account");click("Register");check(hidden("Password")&&hidden("Confirm password"));edit("Password",TextFieldValue("test-only"));edit("Confirm password",TextFieldValue("test-only"));click("Show Password");click("Show Confirm password");disposals.toList().forEach {it()};render();check(fields.getValue("Password").value.text.isEmpty());check(fields.getValue("Confirm password").value.text.isEmpty());check(hidden("Password")&&hidden("Confirm password"));check(Memory.saved==setOf(0,1,2))}
 TEST fun pendingAndRestoringDisableEditorsAndRevealControls(){setup();click("Register");for(state in listOf(AuthState.Pending,AuthState.Restoring)){render(state);check(fields.values.all {!it.enabled});check(actions.getValue("Show Password").enabled.not());check(actions.getValue("Show Confirm password").enabled.not());fields.getValue("Confirm password").keys.onDone!!.invoke();check(model.submissions.isEmpty())}}
 TEST fun defaultFieldRemainsRoleFree(){fields.clear();SoundQEntryField(TextFieldValue("ordinary"),{},"Ordinary");check(fields.getValue("Ordinary").modifier.properties["role"]==null)}
 TEST fun compositionValidationAndExplicitSubmitRemainUnchanged(){setup();edit("Email",TextFieldValue("synthetic@example.test"));edit("Password",TextFieldValue("test-only",composition=TextRange(0,2)));fields.getValue("Password").keys.onDone!!.invoke();check(model.submissions.isEmpty());edit("Password",TextFieldValue("test-only"));fields.getValue("Password").keys.onDone!!.invoke();check(model.submissions==listOf(Triple("synthetic@example.test","test-only",null)));click("Register");edit("Username",TextFieldValue("Synthetic"));edit("Password",TextFieldValue("test-only"));edit("Confirm password",TextFieldValue("mismatch"));fields.getValue("Confirm password").keys.onDone!!.invoke();check(model.submissions.size==1);edit("Confirm password",TextFieldValue("test-only"));fields.getValue("Confirm password").keys.onDone!!.invoke();check(model.submissions.last()==Triple("synthetic@example.test","test-only","Synthetic"))}
}
fun main(){val test=AuthAutofillConfigurationTest();var failed=0
 for(name in listOf(NAMES)){try {test.javaClass.getMethod(name).invoke(test);println("PASS $name")}catch(e:Throwable){failed++;println("FAIL $name: ${e.cause?.message?:e.message}")}}
 check(failed==0){"$failed configuration/body failures"}
}
'''
import re
# Mode-action labels changed; keep the existing editor, lifecycle and submit assertions intact.
tests=tests.replace('click("Register")','click("Create account")').replace('click("Use an existing account")','click("Sign in")')
names=re.findall(r'TEST fun (\w+)\(',tests)
text=prelude.replace('ANNOTATION_IMPORT','' if a.standalone else 'import org.junit.Test')+'\n'+field+'\n'+auth+'\n'+tests.replace('TEST ','' if a.standalone else '@Test ').replace('NAMES',','.join('"'+n+'"' for n in names))
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'AuthAutofillConfigurationTest.kt').write_text(text)
print('Generated configuration-only auth caller/editor probe:',len(names),'cases')
