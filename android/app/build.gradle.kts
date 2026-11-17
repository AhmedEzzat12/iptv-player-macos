// The Google TV app. Shown to users as "Antenna" (store name); code stays "Tuner".

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

/** Build number = commit count, like CFBundleVersion on the Apple apps; 1 outside a git checkout. */
val commitCount: Int = providers.exec {
    commandLine("git", "rev-list", "--count", "HEAD")
    isIgnoreExitValue = true
}.standardOutput.asText.map { it.trim().toIntOrNull() ?: 1 }.getOrElse(1)

android {
    namespace = "app.tuner.tv"
    compileSdk = TunerBuild.COMPILE_SDK

    defaultConfig {
        applicationId = TunerBuild.APPLICATION_ID
        minSdk = TunerBuild.MIN_SDK
        targetSdk = TunerBuild.TARGET_SDK
        versionCode = commitCount
        versionName = rootProject.file("VERSION").readText().trim()
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        // For the owner's TV: installs next to any copy they use (app.antenna.player.scratch), never over it.
        create("scratch") {
            initWith(getByName("release"))
            applicationIdSuffix = ".scratch"
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += "release"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.toVersion(TunerBuild.JAVA_TARGET)
        targetCompatibility = JavaVersion.toVersion(TunerBuild.JAVA_TARGET)
    }

    buildFeatures { compose = true }
}

kotlin {
    compilerOptions {
        optIn.add("androidx.tv.material3.ExperimentalTvMaterial3Api")
    }
}

dependencies {
    implementation(project(":data"))
    implementation(project(":player"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.foundation)
    implementation(libs.compose.ui)
    implementation(libs.compose.material.icons)
    implementation(libs.tv.material)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.hls)
    implementation(libs.media3.okhttp)
    implementation(libs.media3.ui)
    implementation(libs.media3.session)
    implementation(libs.tvprovider)
    implementation(libs.coil.compose)
    implementation(libs.coil.okhttp)
    implementation(libs.zxing.core)
}
