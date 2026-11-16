// Room database, sync and guide services, secrets (phase 3).
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "app.tuner.data"
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
