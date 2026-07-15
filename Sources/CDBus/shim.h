// Sammel-Header fuer das CDBus-Systemmodul.
//
// dbus.h ist der offizielle Einstiegspunkt der libdbus-1-Nutzer-API
// (Paket libdbus-1-dev). Anders als die meisten C-Bibliotheken verteilt D-Bus
// seine Header auf ZWEI Verzeichnisse — /usr/include/dbus-1.0 und einen
// architekturabhaengigen Pfad mit dbus-arch-deps.h. Genau deshalb geht der
// Include-Pfad ueber pkg-config (`pkgConfig: "dbus-1"` in Package.swift) und
// nicht ueber einen fest verdrahteten Pfad.
#include <dbus/dbus.h>
