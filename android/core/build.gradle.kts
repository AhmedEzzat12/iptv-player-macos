// UI-free domain logic ported from Sources/TunerCore (parsers, providers, models). Plain JVM, so its tests run fast
// on the Mac without an emulator. Bytecode level matches the Android modules: this code is dexed into the app.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    id("ru.vyarus.animalsniffer") version "2.0.1"
}

java {
    sourceCompatibility = JavaVersion.toVersion(TunerBuild.JAVA_TARGET)
    targetCompatibility = JavaVersion.toVersion(TunerBuild.JAVA_TARGET)
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.fromTarget(TunerBuild.JAVA_TARGET.toString()))
        allWarningsAsErrors.set(true)
    }
}

dependencies {
    // Java APIs core may call: Android API 28 (minSdk). Checked by the animalsniffer tasks (`check`).
    signature("com.toasttab.android:gummy-bears-api-28:0.12.0@signature")
    implementation(libs.kotlinx.coroutines.core)
    api(libs.kotlinx.serialization.json)
    api(libs.okhttp)
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testImplementation(kotlin("test"))
    testImplementation(libs.okhttp.mockwebserver)
    testRuntimeOnly(libs.junit.platform.launcher)
}

tasks.test {
    useJUnitPlatform()
    // Shared test vectors live in the Apple tree (Tests/Vectors) and are read in place.
    systemProperty("tuner.vectors", rootProject.file("../Tests/Vectors").absolutePath)
    systemProperty("tuner.fixtures", rootProject.file("../Tests/TunerCoreTests/Fixtures").absolutePath)
}

// The checker's bundled ASM predates Java 26 class files. `check` (and so scripts/check-build.sh) runs it: core is plain
// JVM code dexed into the app, and two Java 9+ calls here already crashed older TVs before this existed.
configurations.matching { it.name == "animalsniffer" }.configureEach {
    resolutionStrategy.force("org.ow2.asm:asm:9.9")
}
