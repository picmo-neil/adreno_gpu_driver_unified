package io.github.adreno.qgl.trigger

object ProfileManager {

    @Volatile private var cachedSrcPath: String? = null
    @Volatile private var cachedLastModified: Long = 0L

    @Synchronized fun invalidateCache() {
        cachedSrcPath = null
        cachedLastModified = 0L
    }
}
