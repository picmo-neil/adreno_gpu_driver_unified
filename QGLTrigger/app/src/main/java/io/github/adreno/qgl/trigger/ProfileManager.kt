package io.github.adreno.qgl.trigger

import android.util.Log
import java.io.File
import java.io.IOException

private const val TAG = "QGLTrigger"
private const val PROFILE_PATH_SD = "/sdcard/Adreno_Driver/Config/qgl_profiles.json"
private const val PROFILE_PATH_DATA = "/data/local/tmp/qgl_profiles.json"
private const val MAX_PROFILE_SIZE = 1024 * 1024L

object ProfileManager {

    @Volatile private var cachedProfile: QGLProfile? = null
    @Volatile private var lastLoadTime: Long = 0L
    private const val CACHE_TTL_MS = 5000L
    private val cacheLock = Any()

    fun getProfile(): QGLProfile? {
        val now = System.currentTimeMillis()
        val cached = cachedProfile
        val lastLoad = lastLoadTime
        if (cached != null && (now - lastLoad) < CACHE_TTL_MS) {
            return cached
        }
        return loadProfile()
    }

    fun getKeysForPackage(packageName: String): List<String>? {
        val profile = getProfile() ?: return null

        val appProfile = profile.apps[packageName]
        if (appProfile != null && appProfile.enabled) {
            Log.d(TAG, "Found app-specific profile for $packageName with ${appProfile.keys.size} keys")
            return appProfile.keys
        }

        val global = profile.global
        if (global != null && global.enabled) {
            Log.d(TAG, "Falling back to global profile for $packageName with ${global.keys.size} keys")
            return global.keys
        }

        Log.d(TAG, "No enabled profile found for $packageName")
        return null
    }

    private fun resolveProfileFile(): File? {
        val sdFile = File(PROFILE_PATH_SD)
        if (sdFile.exists() && sdFile.canRead()) return sdFile

        val dataFile = File(PROFILE_PATH_DATA)
        if (dataFile.exists() && dataFile.canRead()) return dataFile

        return null
    }

    private fun loadProfile(): QGLProfile? {
        val file = resolveProfileFile()
        if (file == null) {
            Log.w(TAG, "No readable profile file found (tried $PROFILE_PATH_SD and $PROFILE_PATH_DATA)")
            return null
        }

        if (file.length() > MAX_PROFILE_SIZE) {
            Log.e(TAG, "Profile file too large: ${file.length()} bytes (max: $MAX_PROFILE_SIZE)")
            return null
        }

        return try {
            val content = file.readText()
            val profile = parseJson(content)
            synchronized(cacheLock) {
                cachedProfile = profile
                lastLoadTime = System.currentTimeMillis()
            }
            Log.d(TAG, "Successfully loaded profile from ${file.path} with ${profile.apps.size} app entries")
            profile
        } catch (e: IOException) {
            Log.e(TAG, "Failed to read profile file", e)
            null
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse profile JSON", e)
            null
        }
    }

    private fun parseJson(json: String): QGLProfile {
        val parser = JsonParser(json)
        return parser.parseProfile()
    }

    private class JsonParser(private val json: String) {
        private var pos = 0

        fun parseProfile(): QGLProfile {
            skipWhitespace()
            expectChar('{')

            var global: GlobalProfile? = null
            val apps = mutableMapOf<String, AppProfile>()

            while (pos < json.length) {
                skipWhitespace()
                if (peek() == '}') {
                    pos++
                    break
                }

                val key = parseString()
                skipWhitespace()
                expectChar(':')
                skipWhitespace()

                when (key) {
                    "global" -> global = parseGlobalProfile()
                    "apps" -> apps.putAll(parseAppsMap())
                    else -> skipValue()
                }

                skipWhitespace()
                if (pos < json.length && peek() == ',') {
                    pos++
                }
            }

            return QGLProfile(global = global, apps = apps)
        }

        private fun parseGlobalProfile(): GlobalProfile {
            skipWhitespace()
            expectChar('{')

            var keys: List<String> = emptyList()
            var enabled = true

            while (pos < json.length) {
                skipWhitespace()
                if (peek() == '}') {
                    pos++
                    break
                }

                val k = parseString()
                skipWhitespace()
                expectChar(':')
                skipWhitespace()

                when (k) {
                    "keys" -> keys = parseStringArray()
                    "enabled" -> enabled = parseBoolean()
                    else -> skipValue()
                }

                skipWhitespace()
                if (pos < json.length && peek() == ',') {
                    pos++
                }
            }

            return GlobalProfile(keys = keys, enabled = enabled)
        }

        private fun parseAppsMap(): Map<String, AppProfile> {
            val apps = mutableMapOf<String, AppProfile>()
            skipWhitespace()
            expectChar('{')

            while (pos < json.length) {
                skipWhitespace()
                if (peek() == '}') {
                    pos++
                    break
                }

                val pkgName = parseString()
                skipWhitespace()
                expectChar(':')
                skipWhitespace()

                val appProfile = parseAppProfile()
                apps[pkgName] = appProfile

                skipWhitespace()
                if (pos < json.length && peek() == ',') {
                    pos++
                }
            }

            return apps
        }

        private fun parseAppProfile(): AppProfile {
            skipWhitespace()
            expectChar('{')

            var keys: List<String> = emptyList()
            var enabled = true

            while (pos < json.length) {
                skipWhitespace()
                if (peek() == '}') {
                    pos++
                    break
                }

                val k = parseString()
                skipWhitespace()
                expectChar(':')
                skipWhitespace()

                when (k) {
                    "keys" -> keys = parseStringArray()
                    "enabled" -> enabled = parseBoolean()
                    else -> skipValue()
                }

                skipWhitespace()
                if (pos < json.length && peek() == ',') {
                    pos++
                }
            }

            return AppProfile(keys = keys, enabled = enabled)
        }

        private fun parseStringArray(): List<String> {
            val list = mutableListOf<String>()
            skipWhitespace()
            expectChar('[')

            while (pos < json.length) {
                skipWhitespace()
                if (peek() == ']') {
                    pos++
                    break
                }

                skipWhitespace()
                val item = parseString()
                list.add(item)

                skipWhitespace()
                if (pos < json.length && peek() == ',') {
                    pos++
                }
            }

            return list
        }

        private fun parseString(): String {
            skipWhitespace()
            expectChar('"')

            val sb = StringBuilder()
            while (pos < json.length) {
                val ch = json[pos]
                pos++
                if (ch == '\\') {
                    if (pos < json.length) {
                        val escaped = json[pos]
                        pos++
                        sb.append(
                            when (escaped) {
                                'n' -> '\n'
                                't' -> '\t'
                                'r' -> '\r'
                                'b' -> '\b'
                                'f' -> '\u000C'
                                '"' -> '"'
                                '\\' -> '\\'
                                '/' -> '/'
                                'u' -> {
                                    if (pos + 4 <= json.length) {
                                        val hex = json.substring(pos, pos + 4)
                                        pos += 4
                                        hex.toIntOrNull(16)?.toChar() ?: '?'
                                    } else {
                                        '?'
                                    }
                                }
                                else -> escaped
                            }
                        )
                    }
                } else if (ch == '"') {
                    break
                } else {
                    sb.append(ch)
                }
            }

            return sb.toString()
        }

        private fun parseBoolean(): Boolean {
            skipWhitespace()
            return if (json.startsWith("true", pos)) {
                val after = pos + 4
                if (after < json.length && json[after].isLetterOrDigit()) {
                    Log.w(TAG, "Invalid boolean at position $pos: not followed by delimiter")
                    false
                } else {
                    pos = after
                    true
                }
            } else if (json.startsWith("false", pos)) {
                val after = pos + 5
                if (after < json.length && json[after].isLetterOrDigit()) {
                    Log.w(TAG, "Invalid boolean at position $pos: not followed by delimiter")
                    false
                } else {
                    pos = after
                    false
                }
            } else {
                Log.w(TAG, "Unexpected boolean value at position $pos")
                false
            }
        }

        private fun skipValue() {
            skipWhitespace()
            when (peek()) {
                '"' -> {
                    parseString()
                }
                '{' -> {
                    pos++
                    var depth = 1
                    var inString = false
                    while (pos < json.length && depth > 0) {
                        val ch = json[pos]
                        pos++
                        if (inString) {
                            if (ch == '\\') {
                                pos++
                            } else if (ch == '"') {
                                inString = false
                            }
                        } else {
                            when (ch) {
                                '"' -> inString = true
                                '{' -> depth++
                                '}' -> depth--
                            }
                        }
                    }
                }
                '[' -> {
                    pos++
                    var depth = 1
                    var inString = false
                    while (pos < json.length && depth > 0) {
                        val ch = json[pos]
                        pos++
                        if (inString) {
                            if (ch == '\\') {
                                pos++
                            } else if (ch == '"') {
                                inString = false
                            }
                        } else {
                            when (ch) {
                                '"' -> inString = true
                                '[' -> depth++
                                ']' -> depth--
                            }
                        }
                    }
                }
                else -> {
                    while (pos < json.length) {
                        val ch = json[pos]
                        if (ch == ',' || ch == '}' || ch == ']' || ch.isWhitespace()) {
                            break
                        }
                        pos++
                    }
                }
            }
        }

        private fun peek(): Char {
            if (pos >= json.length) {
                throw IllegalStateException("Unexpected end of JSON at position $pos")
            }
            return json[pos]
        }

        private fun expectChar(expected: Char) {
            skipWhitespace()
            if (pos >= json.length) {
                throw IllegalStateException("Unexpected end of JSON, expected '$expected'")
            }
            if (json[pos] != expected) {
                throw IllegalStateException(
                    "Expected '$expected' at position $pos but found '${json[pos]}'"
                )
            }
            pos++
        }

        private fun skipWhitespace() {
            while (pos < json.length && json[pos].isWhitespace()) {
                pos++
            }
        }
    }
}
