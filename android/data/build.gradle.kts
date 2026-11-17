// Room database, sync and guide services, secrets (phase 3).
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
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
    implementation(libs.kotlinx.coroutines.core)
    api(libs.room.runtime)
    implementation(libs.room.ktx)
    ksp(libs.room.compiler)
}

ksp {
    arg("room.schemaLocation", "$projectDir/schemas")
}
