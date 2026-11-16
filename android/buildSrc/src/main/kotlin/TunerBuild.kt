/** Build settings shared by every module (one place to change them). */
object TunerBuild {
    /** Store identity, shared with the App Store apps; code and modules stay "Tuner". */
    const val APPLICATION_ID = "app.antenna.player"
    const val MIN_SDK = 28
    const val COMPILE_SDK = 37
    /** Play's current target API requirement. */
    const val TARGET_SDK = 36
    /**
     * Bytecode level for all modules: the highest the toolchain accepts (checked 2026-11-16: Kotlin 2.4.21 stops at
     * 26, "Unknown Kotlin JVM target: 27"; AGP 9.5.1's D8 dexes 26). The build itself runs on the latest stable JDK
     * (android/scripts/env.sh). Raise it when Kotlin and D8 accept the newer level.
     */
    const val JAVA_TARGET = 26
}
