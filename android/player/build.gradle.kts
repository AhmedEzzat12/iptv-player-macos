// Playback engines (ExoPlayer, libmpv), routing and watchdog (phase 4).
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "app.tuner.player"
    compileSdk = TunerBuild.COMPILE_SDK
    defaultConfig { minSdk = TunerBuild.MIN_SDK }
    compileOptions {
        sourceCompatibility = JavaVersion.toVersion(TunerBuild.JAVA_TARGET)
        targetCompatibility = JavaVersion.toVersion(TunerBuild.JAVA_TARGET)
    }
}

dependencies {
    api(project(":core"))
}
