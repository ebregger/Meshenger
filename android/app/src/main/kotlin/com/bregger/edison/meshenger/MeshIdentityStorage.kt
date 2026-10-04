package com.bregger.edison.meshenger

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Encrypts the identity seed with an Android Keystore key outside backup storage. */
class MeshIdentityStorage(context: Context) {
  private val seedFile = AtomicFile(File(context.noBackupFilesDir, "mesh_identity_v1"))
  private val alias = "MeshengerIdentityWrappingKeyV1"

  @Synchronized
  fun readSeed(): String? {
    if (!seedFile.baseFile.exists() && !File(seedFile.baseFile.path + ".bak").exists()) return null
    require(seedFile.baseFile.length() <= 1024) { "Invalid identity storage size" }
    val packed = seedFile.readFully()
    require(packed.size == 61 && packed[0] == 1.toByte()) { "Invalid identity storage format" }
    val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    val key = keyStore.getKey(alias, null) as? SecretKey
      ?: error("Identity encryption key is unavailable; identity was not replaced")
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, packed.copyOfRange(1, 13)))
    val seed = cipher.doFinal(packed.copyOfRange(13, packed.size))
    require(seed.size == 32) { "Invalid identity seed" }
    return Base64.encodeToString(seed, Base64.NO_WRAP)
  }

  @Synchronized
  fun writeSeed(encoded: String) {
    val seed = Base64.decode(encoded, Base64.DEFAULT)
    require(seed.size == 32) { "Identity seed must contain 32 bytes" }
    val existing = readSeed()
    if (existing != null) {
      require(existing == Base64.encodeToString(seed, Base64.NO_WRAP)) { "Refusing to replace an existing identity" }
      return
    }
    val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    val key = keyStore.getKey(alias, null) as? SecretKey ?: KeyGenerator.getInstance(
      KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore",
    ).apply {
      init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
        .setKeySize(256)
        .build())
    }.generateKey()
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, key)
    val packed = byteArrayOf(1) + cipher.iv + cipher.doFinal(seed)
    val output = seedFile.startWrite()
    try {
      output.write(packed)
      seedFile.finishWrite(output)
    } catch (error: Throwable) {
      seedFile.failWrite(output)
      throw error
    }
  }
}
