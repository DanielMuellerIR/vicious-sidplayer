// Dieses Target ist eine App-Extension (.appex): Der echte Einstiegspunkt ist
// NSExtensionMain (per Linker-Flag "-e _NSExtensionMain" in Package.swift).
// SwiftPM verlangt fuer executable-Targets trotzdem eine main.swift — dieser
// Top-Level-Code wird nie ausgefuehrt.
