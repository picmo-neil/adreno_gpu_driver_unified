plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.github.adreno.qgl.trigger"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.github.adreno.qgl.trigger"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    // Use debug signing config (Gradle's default) - works without keystore
    // Custom keystore only needed if specifically building for release store
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            // Use debug signing (default Android behavior)
            // This allows building without a keystore file
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            isMinifyEnabled = false
            isShrinkResources = false
            // Debug builds use debug signing by default
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
        }
    }
}

// Optional: Load custom keystore if it exists (for release builds with real certificate)
val customKeystore = file("debug.keystore")
if (customKeystore.exists()) {
    android.signingConfigs.create("release") {
        storeFile = customKeystore
        storePassword = "android"
        keyAlias = "androiddebugkey"
        keyPassword = "android"
    }
    android.buildTypes.getByName("release") {
        signingConfig = android.signingConfigs.getByName("release")
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.16.0")
}