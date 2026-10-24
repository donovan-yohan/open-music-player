#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "soundq_core.h"

/* JNI GetStringUTFChars is modified UTF-8 (surrogate encoding), not Rust UTF-8.
 * Use Java's standard UTF-8 encoder in both directions. Inputs are copied and
 * never retained past the ABI call. */
static char *utf8(JNIEnv *env, jstring text) {
    if (!text) return NULL;
    jclass string = (*env)->FindClass(env, "java/lang/String");
    jmethodID get_bytes = (*env)->GetMethodID(env, string, "getBytes", "(Ljava/lang/String;)[B");
    jstring charset = (*env)->NewStringUTF(env, "UTF-8");
    jbyteArray bytes = (jbyteArray)(*env)->CallObjectMethod(env, text, get_bytes, charset);
    if ((*env)->ExceptionCheck(env) || !bytes) return NULL;
    jsize size = (*env)->GetArrayLength(env, bytes);
    if (size > 65536) return NULL;
    char *copy = malloc((size_t)size + 1);
    if (!copy) return NULL;
    (*env)->GetByteArrayRegion(env, bytes, 0, size, (jbyte *)copy);
    copy[size] = 0;
    if (memchr(copy, 0, (size_t)size)) { free(copy); return NULL; }
    return copy;
}
JNIEXPORT jint JNICALL Java_com_soundq_nativepreview_CoreBridge_version(JNIEnv *env, jobject self) {
    (void)env; (void)self; return (jint)sq_core_abi_version();
}
JNIEXPORT jlong JNICALL Java_com_soundq_nativepreview_CoreBridge_open(JNIEnv *env, jobject self, jstring endpoint, jstring root) {
    (void)self;
    char *e = utf8(env, endpoint), *r = utf8(env, root);
    uint64_t handle = (e && r) ? sq_core_open(e, r) : 0;
    free(e); free(r);
    return (jlong)handle;
}
JNIEXPORT jstring JNICALL Java_com_soundq_nativepreview_CoreBridge_execute(JNIEnv *env, jobject self, jlong handle, jlong epoch, jstring command) {
    (void)self;
    char *input = utf8(env, command);
    if (!input) return NULL;
    char *result = sq_core_execute((uint64_t)handle, (uint64_t)epoch, input);
    free(input);
    if (!result) return NULL;
    jsize size = (jsize)strlen(result);
    jbyteArray bytes = (*env)->NewByteArray(env, size);
    if (!bytes) { sq_core_string_free(result); return NULL; }
    (*env)->SetByteArrayRegion(env, bytes, 0, size, (const jbyte *)result);
    sq_core_string_free(result);
    jclass string = (*env)->FindClass(env, "java/lang/String");
    jmethodID init = (*env)->GetMethodID(env, string, "<init>", "([BLjava/lang/String;)V");
    jstring charset = (*env)->NewStringUTF(env, "UTF-8");
    return (jstring)(*env)->NewObject(env, string, init, bytes, charset);
}
JNIEXPORT jlong JNICALL Java_com_soundq_nativepreview_CoreBridge_revoke(JNIEnv *env, jobject self, jlong handle) {
    (void)env; (void)self; return (jlong)sq_core_revoke((uint64_t)handle);
}
JNIEXPORT void JNICALL Java_com_soundq_nativepreview_CoreBridge_close(JNIEnv *env, jobject self, jlong handle) {
    (void)env; (void)self; sq_core_close((uint64_t)handle);
}
