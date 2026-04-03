# QGL Trigger ProGuard Rules
-keep class io.github.adreno.qgl.trigger.ConfigKt { *; }
-keep class io.github.adreno.qgl.trigger.QGLProfile { *; }
-keep class io.github.adreno.qgl.trigger.GlobalProfile { *; }
-keep class io.github.adreno.qgl.trigger.AppProfile { *; }
-keepclassmembers class io.github.adreno.qgl.trigger.ProfileManager$JsonParser { *; }
