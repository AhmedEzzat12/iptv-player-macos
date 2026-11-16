// UI-free domain logic ported from Sources/TunerCore (parsers, providers, models). Plain JVM, so its tests run fast
// on the Mac without an emulator. Bytecode level matches the Android modules: this code is dexed into the app.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
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
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testImplementation(kotlin("test"))
    testRuntimeOnly(libs.junit.platform.launcher)
}

tasks.test {
    useJUnitPlatform()
    // Shared test vectors live in the Apple tree (Tests/Vectors) and are read in place.
    systemProperty("tuner.vectors", rootProject.file("../Tests/Vectors").absolutePath)
}
