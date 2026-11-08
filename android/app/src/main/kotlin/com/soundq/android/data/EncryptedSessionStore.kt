package com.soundq.android.data

import java.io.*
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Versioned encrypted atomic file, rejects without altering corrupt/future/foreign bytes. */
class EncryptedSessionStore(private val file: File, private val key: () -> SecretKey) : SessionStore {
    @Synchronized override fun load(endpoint: ApiEndpoint): SecretTokens? {
        if (!file.exists()) return null
        try {
            require(file.length() in 30..65536)
            val input=DataInputStream(ByteArrayInputStream(file.readBytes()))
            require(input.readInt()==1)
            val iv=ByteArray(12); input.readFully(iv)
            val cipher=Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,iv)); cipher.updateAAD(endpoint.identity.toByteArray())
            val plain=cipher.doFinal(input.readBytes())
            return DataInputStream(ByteArrayInputStream(plain)).use {
                require(it.readUTF()==endpoint.identity)
                val tokens=SecretTokens(it.readUTF(),it.readUTF(),it.readUTF()); require(it.available()==0); tokens
            }
        } catch(_: Exception) { throw SafeFailure(SafeFailure.Reason.StoreRejected) }
    }
    @Synchronized override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {
        val plain=ByteArrayOutputStream().also { bytes -> DataOutputStream(bytes).use {it.writeUTF(endpoint.identity);it.writeUTF(tokens.access);it.writeUTF(tokens.refresh);it.writeUTF(tokens.accountId)} }.toByteArray()
        val cipher=Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE,key()); cipher.updateAAD(endpoint.identity.toByteArray())
        val encrypted=cipher.doFinal(plain)
        require(cipher.iv.size==12)
        file.parentFile!!.mkdirs()
        val temp=File(file.parentFile,file.name+".new")
        try {
            FileOutputStream(temp).use { stream ->
                DataOutputStream(stream).apply {writeInt(1);write(cipher.iv);write(encrypted);flush()}; stream.fd.sync()
            }
            Files.move(temp.toPath(),file.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
        } finally {temp.delete(); plain.fill(0)}
    }
    @Synchronized override fun clear() {
        if(file.exists() && !file.delete()) throw java.io.IOException("Secure session removal failed")
        File(file.parentFile,file.name+".new").delete()
    }
}
