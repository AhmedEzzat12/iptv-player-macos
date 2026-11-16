package app.tuner.core

/**
 * Marker for the domain module. Ports of `Sources/TunerCore` land in packages named after their Swift folders
 * (`parsing`, `providers`, `models`, …); see docs/superpowers/specs/google-tv/A-port-map.md.
 */
public object TunerCore {
    /** The Apple commit the port follows (android/PARITY_BASE), for diagnostics. */
    public const val PORTED_FROM: String = "666f598"
}
