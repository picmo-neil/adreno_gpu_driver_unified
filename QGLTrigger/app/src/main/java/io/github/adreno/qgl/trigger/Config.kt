package io.github.adreno.qgl.trigger

data class QGLProfile(
    val global: GlobalProfile?,
    val apps: Map<String, AppProfile>
)

data class GlobalProfile(
    val keys: List<String>,
    val enabled: Boolean
)

data class AppProfile(
    val keys: List<String>,
    val enabled: Boolean
)
