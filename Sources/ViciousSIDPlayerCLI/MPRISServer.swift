// ============================================================================
// MPRISServer — der Player als Bedienobjekt des Linux-Desktops.
//
// Die GANZE Datei steckt in `#if os(Linux)`, denn D-Bus gibt es nur dort. Auf dem
// Mac faellt sie ersatzlos weg — dieselbe Aufgabe erledigen dort
// MPRemoteCommandCenter und MPNowPlayingInfoCenter.
//
// Was ist D-Bus?
// --------------
// D-Bus ist die Sprechanlage des Linux-Desktops: ein Vermittler, ueber den
// Programme einander Nachrichten schicken, ohne sich zu kennen. Es gibt einen
// System-Bus (Hardware, Netzwerk, Dienste) und pro angemeldetem Nutzer einen
// **Session-Bus** — auf dem laeuft der Desktop, und dort gehoeren wir hin.
//
// Fuenf Begriffe, und man versteht alles Weitere:
//
// * **Bus-Name**: die Adresse eines Programms am Bus, z. B.
//   `org.mpris.MediaPlayer2.vicious-sid`. Wer uns steuern will, schickt seine
//   Nachricht an diesen Namen. Jeder Name gehoert zu jedem Zeitpunkt genau einem
//   Programm.
// * **Objektpfad**: sieht aus wie ein Dateipfad (`/org/mpris/MediaPlayer2`) und
//   benennt EIN Ding innerhalb des Programms. Ein Programm kann viele Objekte
//   anbieten; wir bieten genau eines an.
// * **Interface**: die Gruppe von Methoden/Properties, die ein Objekt beherrscht
//   — vergleichbar mit einem Swift-Protokoll. Unser Objekt erfuellt vier davon.
// * **Property**: ein lesbarer Wert (`PlaybackStatus`, `Metadata`). Properties
//   sind keine eigene Nachrichtenart, sondern laufen ueber die Methoden `Get`
//   und `GetAll` des Interfaces `org.freedesktop.DBus.Properties`.
// * **Signal**: eine Nachricht ohne Empfaenger und ohne Antwort — ein Zuruf an
//   alle Interessierten. Wir senden `PropertiesChanged`, damit das Sound-Applet
//   nicht dauernd nachfragen muss, ob sich etwas geaendert hat.
//
// Und was ist MPRIS2?
// -------------------
// „Media Player Remote Interfacing Specification", Version 2: die Abmachung
// darueber, WELCHE Interfaces ein Musikprogramm anbieten muss, damit der Desktop
// es bedienen kann. Halten wir uns daran, funktionieren Medientasten, das
// Sound-Applet von GNOME/KDE, `playerctl` und Sperrbildschirm-Anzeigen ohne eine
// Zeile Extraarbeit — sie alle sprechen nur diese eine Spezifikation.
//
// Wir implementieren bewusst nur den Teil, den ein SID-Player ehrlich anbieten
// kann: Play/Pause/Stop, Subtune vor/zurueck (das ist unser „Next/Previous"),
// Titel und Autor. Kein Seek (der Emulator kann nicht springen), keine
// Trackliste, keine Lautstaerke.
//
// Thread-Regel dieser Klasse
// --------------------------
// ALLE libdbus-Aufrufe passieren auf dem Bus-Thread — bzw. in `start()`/`stop()`
// zu Zeitpunkten, an denen dieser Thread nachweislich nicht laeuft. Das erspart
// uns jede Frage danach, wie thread-sicher libdbus im Detail ist. Der
// Zustandsbeobachter des Controllers (der auf einem beliebigen Thread feuert)
// setzt deshalb nur ein Flag; gesendet wird das Signal vom Bus-Thread.
// ============================================================================

#if os(Linux)
import Foundation
import CDBus

// MARK: - Konstanten, die Swift nicht aus dem C-Header bekommt

// Die D-Bus-Typkennungen sind in `dbus-protocol.h` Makros der Form
// `#define DBUS_TYPE_STRING ((int) 's')`. Solche Cast-Makros importiert der
// Swift-Clang-Importer NICHT: er uebernimmt nur Makros, die er als schlichte
// Literale erkennt — ein Klammerausdruck mit C-Cast gehoert nicht dazu. In Swift
// existieren `DBUS_TYPE_STRING` und Verwandte deshalb schlicht nicht (nachgeprueft
// am Compiler: „cannot find 'DBUS_TYPE_STRING' in scope"), und wir definieren sie
// hier selbst nach.
//
// Die Grenze verlaeuft genau am Cast: Die schlichten Zahlenmakros derselben
// Bibliothek — `DBUS_NAME_FLAG_REPLACE_EXISTING`, `DBUS_REQUEST_NAME_REPLY_*` —
// kommen als `Int32` sauber herueber und werden unten deshalb auch direkt
// benutzt, statt sie ebenfalls abzuschreiben. Nachgeschrieben wird nur, was
// wirklich fehlt.
//
// Die Werte sind die ASCII-Codes der Typbuchstaben aus der D-Bus-Spezifikation
// und Teil des Drahtformats — sie sind so unveraenderlich wie das Protokoll
// selbst.
//
// Eine Falle steckt darin: Der Typcode fuer einen Dictionary-Eintrag ist 'e',
// obwohl derselbe Eintrag in einer SIGNATUR als '{' geschrieben wird ("a{sv}").
// Wer hier '{' einsetzt, bekommt zur Laufzeit eine Assertion aus libdbus.
private let dbusTypeString = Int32(UInt8(ascii: "s"))
private let dbusTypeObjectPath = Int32(UInt8(ascii: "o"))
private let dbusTypeBoolean = Int32(UInt8(ascii: "b"))
private let dbusTypeDouble = Int32(UInt8(ascii: "d"))
private let dbusTypeInt64 = Int32(UInt8(ascii: "x"))
private let dbusTypeVariant = Int32(UInt8(ascii: "v"))
private let dbusTypeArray = Int32(UInt8(ascii: "a"))
private let dbusTypeDictEntry = Int32(UInt8(ascii: "e"))

/// Wie lange der Bus-Thread hoechstens auf Nachrichten wartet, bevor er sich
/// wieder umschaut. Der Wert ist der Kompromiss zwischen „verbraucht nichts,
/// wenn nichts passiert" und „merkt `stop()` und Zustandsaenderungen zuegig".
/// 100 ms sind fuer ein Sound-Applet nicht wahrnehmbar.
private let busPollTimeoutMilliseconds: Int32 = 100

/// Die Namen, unter denen uns der Desktop findet. Der Objektpfad ist von MPRIS2
/// fest vorgeschrieben — er ist fuer JEDEN Player derselbe, unterschieden werden
/// die Player allein ueber den Bus-Namen.
private enum MPRIS {
    static let busName = "org.mpris.MediaPlayer2.vicious-sid"
    static let objectPath = "/org/mpris/MediaPlayer2"
    static let rootInterface = "org.mpris.MediaPlayer2"
    static let playerInterface = "org.mpris.MediaPlayer2.Player"
    static let propertiesInterface = "org.freedesktop.DBus.Properties"
    static let introspectableInterface = "org.freedesktop.DBus.Introspectable"
}

// MARK: - Fehler

/// Warum die Anmeldung am Bus nicht geklappt hat.
///
/// `LocalizedError` statt eines nackten `Error`: main.swift zeigt
/// `error.localizedDescription` an, und das liefert auf Linux fuer einen
/// gewoehnlichen Error nur einen nichtssagenden Platzhaltertext.
enum MPRISError: LocalizedError {
    /// Es gibt keinen Session-Bus. Voellig normal via SSH, in einem Container
    /// oder auf einem Server ohne Desktop.
    case noSessionBus(String)
    /// Der Bus-Name liess sich nicht belegen — meist laeuft schon ein Player.
    case nameUnavailable(String)
    /// Der Objektpfad liess sich nicht registrieren (praktisch nur bei
    /// Speichermangel).
    case registrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSessionBus(let detail):
            return "kein D-Bus-Session-Bus erreichbar: \(detail)"
        case .nameUnavailable(let detail):
            return "Bus-Name \(MPRIS.busName) nicht verfügbar: \(detail)"
        case .registrationFailed(let detail):
            return "Objektpfad \(MPRIS.objectPath) nicht registrierbar: \(detail)"
        }
    }
}

// MARK: - Werte

/// Ein D-Bus-Wert in genau den Auspraegungen, die MPRIS2 von uns verlangt.
///
/// D-Bus ist streng typisiert: Jeder Wert reist mit einer **Signatur** ueber den
/// Draht ("s" = String, "b" = Boolean, "as" = Array von Strings). Diese Aufzaehlung
/// buendelt Wert und Signatur an einer Stelle, damit beim Schreiben nichts
/// auseinanderlaufen kann.
///
/// `indirect`, weil `.dictionary` wieder Werte enthaelt (die Metadaten sind ein
/// Dictionary aus Strings und String-Arrays).
private indirect enum MPRISValue {
    case boolean(Bool)
    case string(String)
    /// Ein Objektpfad. Auf dem Draht ein String, aber mit eigenem Typ 'o' und
    /// strengeren Regeln (nur A–Z, a–z, 0–9, `_` und `/`).
    case objectPath(String)
    case double(Double)
    case int64(Int64)
    case stringArray([String])
    /// a{sv} — die „Landkarte" aus String-Schluesseln auf beliebige Werte, in der
    /// MPRIS2 die Metadaten transportiert. Bewusst ein Array aus Paaren statt
    /// eines Dictionary: so bleibt die Reihenfolge stabil und damit die Ausgabe
    /// reproduzierbar.
    case dictionary([(String, MPRISValue)])

    /// Die D-Bus-Signatur dieses Wertes.
    var signature: String {
        switch self {
        case .boolean: return "b"
        case .string: return "s"
        case .objectPath: return "o"
        case .double: return "d"
        case .int64: return "x"
        case .stringArray: return "as"
        case .dictionary: return "a{sv}"
        }
    }
}

// MARK: - Server

/// Meldet den Player als MPRIS2-Objekt am Session-Bus an und uebersetzt
/// eingehende Nachrichten in Aufrufe am `PlayerController`.
///
/// Der Server ist nur ein Bedienfeld: Er weiss, WAS passieren soll, nicht WIE.
/// Deshalb koennen Tastatur und MPRIS2 gleichzeitig laufen, ohne sich ins Gehege
/// zu kommen — beide reden mit demselben Controller.
///
/// `@unchecked Sendable`: Die Klasse wird von mehreren Threads benutzt (Aufrufer,
/// Bus-Thread, und der Zustandsbeobachter feuert vom Audio- oder Haupt-Thread).
/// Der veraenderliche Zustand liegt vollstaendig hinter `cond`; das kann der
/// Compiler nicht selbst nachweisen — gleiches Muster wie `ALSAPCMSink`.
final class MPRISServer: @unchecked Sendable {

    private let controller: PlayerController

    /// Schuetzt den Zustand unten UND weckt `stop()`, wenn der Bus-Thread endet.
    private let cond = NSCondition()

    /// `DBusConnection *` — ein unvollstaendiger C-Typ, den Swift als
    /// OpaquePointer importiert. `nil` heisst: nicht (mehr) angemeldet.
    ///
    /// Wird in `start()` gesetzt, bevor der Bus-Thread laeuft, und in `stop()`
    /// geraeumt, nachdem er nachweislich weg ist. Dazwischen fasst ihn nur der
    /// Bus-Thread an.
    private var connection: OpaquePointer?

    /// Der Bus-Thread soll sich beenden.
    private var stopRequested = false
    /// Der Bus-Thread laeuft noch. `stop()` wartet darauf, dass das `false` wird.
    private var threadRunning = false
    /// Es gibt eine Zustandsaenderung, ueber die noch niemand informiert wurde.
    /// Gesetzt vom Beobachter (irgendein Thread), abgeraeumt vom Bus-Thread.
    private var changePending = false

    init(controller: PlayerController) {
        self.controller = controller
    }

    // MARK: - Anmelden

    /// Meldet den Player am Session-Bus an und startet den Bus-Thread.
    ///
    /// Wirft, wenn es keinen Session-Bus gibt (SSH, Container, Server ohne
    /// Desktop) oder der Bus-Name schon belegt ist. Beides ist kein Grund, die
    /// Wiedergabe abzubrechen — main.swift faengt das ab und spielt weiter.
    func start() throws {
        cond.lock()
        // Zweiter Aufruf: schon angemeldet, nichts zu tun.
        guard connection == nil, !stopRequested else {
            cond.unlock()
            return
        }
        cond.unlock()

        // `DBusError` ist die Art, wie libdbus Fehler herausreicht: eine Struktur,
        // die der Aufrufer stellt und die die Bibliothek bei Bedarf mit Name und
        // Text fuellt. Sie MUSS vor der ersten Nutzung initialisiert und danach
        // freigegeben werden — der Text darin ist auf dem Heap alloziert, und ohne
        // `dbus_error_free` leckt er.
        var error = DBusError()
        dbus_error_init(&error)
        defer { dbus_error_free(&error) }

        // --- Verbindung aufbauen ---------------------------------------------
        //
        // `_private` und nicht das gewoehnliche `dbus_bus_get` ist Absicht:
        // `dbus_bus_get` liefert eine GETEILTE Verbindung, die libdbus intern
        // zwischenspeichert und die man laut Dokumentation nicht schliessen darf
        // (`dbus_connection_close` darauf ist ein Programmierfehler und wird von
        // libdbus angemeckert). Wir wollen uns in `stop()` aber sauber abmelden.
        // Eine private Verbindung gehoert uns allein — wir duerfen und muessen sie
        // schliessen.
        guard let connection = dbus_bus_get_private(DBUS_BUS_SESSION, &error) else {
            throw MPRISError.noSessionBus(MPRISServer.text(of: &error))
        }

        // WICHTIG: Die Voreinstellung von libdbus ist, den PROZESS per exit() zu
        // beenden, sobald die Bus-Verbindung wegbricht. Fuer einen Dienst, der ohne
        // Bus sinnlos ist, mag das passen — bei uns wuerde ein Neustart des
        // Session-Busses mitten im Stueck den Player abschiessen. Der Ton ist die
        // Hauptsache, die Desktop-Anbindung die Zugabe: also abschalten.
        dbus_connection_set_exit_on_disconnect(connection, 0)

        // --- Bus-Namen belegen ------------------------------------------------
        //
        // Erst mit diesem Namen sind wir ansprechbar. Bis hierher haben wir nur
        // eine Verbindung, aber keine Adresse.
        //
        // `REPLACE_EXISTING` heisst „nimm mir den Namen notfalls vom bisherigen
        // Besitzer weg". Das ist hier richtig: Ein zweiter Player-Start ersetzt den
        // ersten ohnehin, und ein zurueckgebliebener Eintrag im Sound-Applet waere
        // eine Leiche, die auf Knopfdruck nicht mehr reagiert.
        //
        // Der Cast nach UInt32 ist noetig, weil das Makro als `Int32` importiert
        // wird, der Parameter aber ein `unsigned int` ist.
        let nameResult = dbus_bus_request_name(connection,
                                               MPRIS.busName,
                                               UInt32(DBUS_NAME_FLAG_REPLACE_EXISTING),
                                               &error)
        if dbus_error_is_set(&error) != 0 {
            MPRISServer.discard(connection)
            throw MPRISError.nameUnavailable(MPRISServer.text(of: &error))
        }
        // Alles ausser „wir sind jetzt der Besitzer" ist fuer uns ein Fehlschlag.
        guard nameResult == DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER else {
            // Wir sind nicht Besitzer geworden, sondern hoechstens in der
            // Warteschlange gelandet: Ein anderer Player haelt den Namen und hat
            // sich gegen Abloesung gesperrt. Aus der Warteschlange nehmen wir uns
            // gleich wieder heraus — halb angemeldet zu sein waere schlimmer als
            // gar nicht: Der Desktop wuerde uns irgendwann uebernehmen, ohne dass
            // jemand damit rechnet.
            _ = dbus_bus_release_name(connection, MPRIS.busName, nil)
            MPRISServer.discard(connection)
            throw MPRISError.nameUnavailable("ein anderer Player hält ihn bereits")
        }

        // --- Objekt anbieten ---------------------------------------------------
        //
        // Die VTable sagt libdbus, welche Funktion bei einer Nachricht an diesen
        // Objektpfad gerufen werden soll.
        //
        // Zwei Fallen auf einmal:
        //
        // 1. Es sind C-Funktionszeiger. Eine Swift-Closure passt dort nur mit
        //    `@convention(c)` hinein — und eine solche Closure darf NICHTS
        //    einfangen, auch nicht `self`. Ein C-Funktionszeiger ist eben nur eine
        //    Adresse; es gibt keinen Platz, an dem eingefangener Zustand haengen
        //    koennte.
        // 2. Genau dafuer gibt es den `user_data`-Zeiger: libdbus reicht ihn bei
        //    jedem Aufruf unveraendert zurueck. Wir schicken `self` hindurch —
        //    `Unmanaged` schaltet dafuer die automatische Speicherverwaltung ab und
        //    liefert eine rohe Adresse.
        //
        // `passUnretained` genuegt: Der Bus-Thread haelt `self` unten stark, und
        // solange er laeuft, kann uns niemand wegraeumen.
        var vtable = DBusObjectPathVTable()
        vtable.message_function = { connection, message, userData in
            guard let userData else {
                // Ohne user_data koennen wir nichts ausrichten. „NOT_YET_HANDLED"
                // heisst: soll sich ein anderer drum kuemmern; libdbus antwortet
                // dem Aufrufer dann selbst mit „unbekannte Methode".
                return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
            }
            let server = Unmanaged<MPRISServer>.fromOpaque(userData).takeUnretainedValue()
            return server.handle(connection: connection, message: message)
        }

        // libdbus uebernimmt die Funktionszeiger beim Registrieren in seine eigene
        // Struktur — diese lokale `vtable` darf danach also verschwinden.
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard dbus_connection_register_object_path(connection,
                                                   MPRIS.objectPath,
                                                   &vtable,
                                                   selfPointer) != 0 else {
            _ = dbus_bus_release_name(connection, MPRIS.busName, nil)
            MPRISServer.discard(connection)
            throw MPRISError.registrationFailed("Speicher erschöpft")
        }

        cond.lock()
        self.connection = connection
        threadRunning = true
        cond.unlock()

        // Ab jetzt interessiert uns, wenn sich am Player etwas tut.
        controller.setStateObserver { [weak self] in
            self?.markChanged()
        }

        // Der Thread faengt `self` bewusst STARK ein (kein `[weak self]`): Solange
        // die Bus-Schleife laeuft, darf dieser Server nicht weggeraeumt werden —
        // sonst zeigte `user_data` oben ins Leere. Ein Retain-Zyklus entsteht
        // dadurch nicht, denn wir halten den Thread umgekehrt nirgends fest;
        // `stop()` wartet ueber `threadRunning` auf ihn statt ueber eine Referenz.
        //
        // Eingefangen wird AUSSCHLIESSLICH `self` — die Verbindung holt sich der
        // Thread unten selbst aus dem Feld. Das ist keine Kosmetik: Der Block
        // eines `Thread` ist `@Sendable`, und `OpaquePointer` ist es nicht. Ihn
        // hier hereinzuziehen lehnt der Compiler zu Recht ab; ein roher Zeiger
        // sagt eben nichts darueber, wer ihn wann anfassen darf. Dass es sicher
        // ist, weiss nur die Thread-Regel dieser Klasse — und die traegt `self`
        // ueber sein `@unchecked Sendable`.
        let thread = Thread {
            self.runBusLoop()
        }
        thread.name = "vicious-sid.mpris"
        thread.start()
    }

    // MARK: - Abmelden

    /// Beendet den Bus-Thread, gibt den Namen frei und schliesst die Verbindung.
    /// Mehrfacher Aufruf ist harmlos, ebenso ein Aufruf nach gescheitertem
    /// `start()`.
    ///
    /// Blockiert bis zu einer Poll-Runde (~100 ms), bis der Bus-Thread wirklich
    /// weg ist. Das ist die Gegenleistung fuer die Thread-Regel dieser Klasse:
    /// Erst wenn niemand mehr die Verbindung anfasst, duerfen wir sie abraeumen.
    func stop() {
        cond.lock()

        // Nie (erfolgreich) gestartet, oder schon gestoppt: nichts zu tun.
        guard let connection else {
            stopRequested = true
            cond.unlock()
            return
        }

        stopRequested = true
        cond.broadcast()

        // Auf den Bus-Thread warten. Er schaut nach jeder Poll-Runde nach dem
        // Flag, also dauert das hoechstens `busPollTimeoutMilliseconds`.
        while threadRunning {
            cond.wait()
        }
        self.connection = nil
        cond.unlock()

        // Den Beobachter abhaengen, BEVOR wir die Verbindung schliessen — sonst
        // koennte eine spaete Zustandsaenderung noch ein Flag setzen, das niemand
        // mehr abraeumt. (Gefaehrlich waere das nicht, nur sinnlos.)
        controller.setStateObserver(nil)

        // Ab hier ist der Bus-Thread nachweislich weg, wir sind also allein mit
        // der Verbindung. Erst den Namen zurueckgeben (damit der Desktop uns
        // sofort aus dem Applet nimmt), dann schliessen.
        _ = dbus_bus_release_name(connection, MPRIS.busName, nil)
        _ = dbus_connection_unregister_object_path(connection, MPRIS.objectPath)
        MPRISServer.discard(connection)
    }

    /// Gibt eine private Verbindung vollstaendig frei.
    ///
    /// Beides ist noetig und in dieser Reihenfolge: `close` trennt die Verbindung
    /// und wirft noch ausstehende Nachrichten weg, `unref` gibt den Speicher frei.
    /// Nur `unref` wuerde den Socket offen lassen — bei einer privaten Verbindung
    /// raeumt ihn niemand sonst weg.
    private static func discard(_ connection: OpaquePointer) {
        dbus_connection_close(connection)
        dbus_connection_unref(connection)
    }

    // MARK: - Bus-Thread

    /// Der Einstiegspunkt des Bus-Threads.
    ///
    /// Holt die Verbindung aus dem Feld (sie steht seit `start()` fest) und meldet
    /// am Ende zuverlaessig ab — `stop()` wartet auf genau dieses Flag, deshalb
    /// darf es auf KEINEM Weg uebersprungen werden.
    private func runBusLoop() {
        cond.lock()
        let connection = self.connection
        cond.unlock()

        if let connection {
            busLoop(connection: connection)
        }

        // `stop()` wartet darauf — und erst danach darf jemand die Verbindung
        // anfassen.
        cond.lock()
        threadRunning = false
        cond.broadcast()
        cond.unlock()
    }

    /// Die eigentliche Schleife: Nachrichten annehmen, ausliefern, ausstehende
    /// Signale senden — bis `stop()` kommt oder die Verbindung wegbricht.
    private func busLoop(connection: OpaquePointer) {
        while true {
            cond.lock()
            let shouldStop = stopRequested
            let hasChange = changePending
            changePending = false
            cond.unlock()

            if shouldStop { break }
            if hasChange { emitPropertiesChanged(connection: connection) }

            // Das Arbeitstier: wartet auf Daten, liest sie, und ruft fuer jede
            // fertige Nachricht unsere `message_function` auf — alles in einem
            // Aufruf.
            //
            // Der Timeout ist der Grund, warum `stop()` ueberhaupt greift: Ohne ihn
            // (also mit -1) haenge der Thread unbegrenzt im Warten, und niemand
            // koennte ihn ohne Tricks herausholen. So schaut er spaetestens nach
            // 100 ms wieder oben nach dem Stop-Flag.
            //
            // Rueckgabe 0 heisst „Verbindung ist getrennt": Dann kommt nichts mehr,
            // und weiterzupollen waere nur eine Leerlaufschleife.
            if dbus_connection_read_write_dispatch(connection, busPollTimeoutMilliseconds) == 0 {
                break
            }
        }
    }

    /// Merkt sich, dass sich am Player etwas geaendert hat.
    ///
    /// Laeuft auf einem fremden Thread (Audio-Thread, Tastaturschleife) und fasst
    /// deshalb bewusst KEINE D-Bus-Funktion an — siehe Thread-Regel oben. Das
    /// Signal schickt der Bus-Thread, sobald er das naechste Mal vorbeikommt.
    private func markChanged() {
        cond.lock()
        changePending = true
        cond.unlock()
    }

    // MARK: - Nachrichten beantworten

    /// Nimmt eine Nachricht entgegen und verteilt sie auf Interface und Methode.
    ///
    /// Laeuft immer auf dem Bus-Thread. Der Controller ist selbst thread-sicher —
    /// wir duerfen ihn hier also einfach rufen.
    private func handle(connection: OpaquePointer?, message: OpaquePointer?) -> DBusHandlerResult {
        guard let connection, let message else {
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
        }

        // Interface und Methode sind die „Anschrift" der Nachricht. Das Interface
        // darf laut Spezifikation fehlen (dann ist es hier schlicht leer) — bei
        // einem Aufruf ohne Interface waere ohnehin unklar, was gemeint ist.
        let interface = dbus_message_get_interface(message).map { String(cString: $0) } ?? ""
        let member = dbus_message_get_member(message).map { String(cString: $0) } ?? ""

        switch (interface, member) {

        // --- Introspection ---------------------------------------------------
        //
        // Ohne das finden viele Clients uns nicht: Sie fragen erst das Objekt, was
        // es kann, und benutzen nur, was in der Antwort steht. Die Antwort ist ein
        // XML-Dokument — der Selbstbeschreibungs-Zettel unseres Objekts.
        case (MPRIS.introspectableInterface, "Introspect"):
            return reply(to: message, on: connection) { iter in
                MPRISServer.append(.string(MPRISServer.introspectionXML), to: &iter)
            }

        // --- Properties -------------------------------------------------------
        case (MPRIS.propertiesInterface, "Get"):
            return handleGet(connection: connection, message: message)

        case (MPRIS.propertiesInterface, "GetAll"):
            return handleGetAll(connection: connection, message: message)

        case (MPRIS.propertiesInterface, "Set"):
            // Wir haben keine schreibbare Property: Lautstaerke regelt der
            // Desktop-Mixer, und Rate kann der Emulator nicht. Ehrlich ablehnen
            // ist besser, als „ok" zu sagen und dann doch den alten Wert zu
            // melden — dann spraenge der Regler im Applet einfach zurueck, ohne
            // dass jemand wuesste, warum.
            return replyError(to: message, on: connection,
                              name: "org.freedesktop.DBus.Error.PropertyReadOnly",
                              text: "Vicious SID Player hat keine schreibbaren Eigenschaften.")

        // --- org.mpris.MediaPlayer2 -------------------------------------------
        case (MPRIS.rootInterface, "Quit"):
            controller.stop()
            return reply(to: message, on: connection)

        case (MPRIS.rootInterface, "Raise"):
            // Wir haben kein Fenster, das man nach vorn holen koennte — deshalb
            // meldet `CanRaise` auch `false`. Ein hoefliches Nicken genuegt.
            return reply(to: message, on: connection)

        // --- org.mpris.MediaPlayer2.Player ------------------------------------
        case (MPRIS.playerInterface, "Play"):
            controller.play()
            return reply(to: message, on: connection)

        case (MPRIS.playerInterface, "Pause"):
            controller.pause()
            return reply(to: message, on: connection)

        case (MPRIS.playerInterface, "PlayPause"):
            controller.playPause()
            return reply(to: message, on: connection)

        case (MPRIS.playerInterface, "Stop"):
            controller.stop()
            return reply(to: message, on: connection)

        case (MPRIS.playerInterface, "Next"):
            // „Naechster Titel" ist bei einer SID-Datei der naechste Subtune —
            // etwas anderes gibt es fuer uns nicht.
            controller.next()
            return reply(to: message, on: connection)

        case (MPRIS.playerInterface, "Previous"):
            controller.previous()
            return reply(to: message, on: connection)

        default:
            // Alles Uebrige geht uns nichts an. libdbus schickt dem Aufrufer dann
            // selbst eine „unbekannte Methode"-Antwort.
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
        }
    }

    /// `Properties.Get(interface, property)` → ein einzelner Wert, verpackt in
    /// eine Variante.
    private func handleGet(connection: OpaquePointer, message: OpaquePointer) -> DBusHandlerResult {
        var iter = DBusMessageIter()
        // Rueckgabe 0 heisst „gar keine Argumente" — dann ist der Aufruf kaputt.
        guard dbus_message_iter_init(message, &iter) != 0,
              let interface = MPRISServer.readString(&iter) else {
            return replyError(to: message, on: connection,
                              name: "org.freedesktop.DBus.Error.InvalidArgs",
                              text: "Get erwartet zwei Strings.")
        }
        // Zum zweiten Argument weiterruecken.
        dbus_message_iter_next(&iter)
        guard let name = MPRISServer.readString(&iter) else {
            return replyError(to: message, on: connection,
                              name: "org.freedesktop.DBus.Error.InvalidArgs",
                              text: "Get erwartet zwei Strings.")
        }

        guard let value = property(interface: interface, name: name) else {
            return replyError(to: message, on: connection,
                              name: "org.freedesktop.DBus.Error.UnknownProperty",
                              text: "\(interface).\(name) gibt es hier nicht.")
        }

        return reply(to: message, on: connection) { out in
            // Get liefert laut Spezifikation immer eine Variante ("v"), nie den
            // nackten Wert — der Aufrufer weiss ja vorher nicht, was kommt.
            MPRISServer.appendVariant(value, to: &out)
        }
    }

    /// `Properties.GetAll(interface)` → alle Werte eines Interfaces auf einen
    /// Schlag. Die meisten Clients fragen genau das einmal beim Verbinden.
    private func handleGetAll(connection: OpaquePointer, message: OpaquePointer) -> DBusHandlerResult {
        var iter = DBusMessageIter()
        guard dbus_message_iter_init(message, &iter) != 0,
              let interface = MPRISServer.readString(&iter) else {
            return replyError(to: message, on: connection,
                              name: "org.freedesktop.DBus.Error.InvalidArgs",
                              text: "GetAll erwartet einen String.")
        }

        // Ein unbekanntes Interface ist kein Fehler: Die Spezifikation sieht dafuer
        // eine leere Landkarte vor. Ein Client, der auf gut Glueck nach
        // `TrackList` fragt, soll keine Fehlermeldung bekommen.
        let values = properties(of: interface)
        return reply(to: message, on: connection) { out in
            MPRISServer.append(.dictionary(values), to: &out)
        }
    }

    // MARK: - Properties

    /// Alle Properties eines Interfaces, in stabiler Reihenfolge.
    private func properties(of interface: String) -> [(String, MPRISValue)] {
        switch interface {
        case MPRIS.rootInterface:
            return [
                ("CanQuit", .boolean(true)),
                // Kein Fenster, nichts nach vorn zu holen — siehe `Raise`.
                ("CanRaise", .boolean(false)),
                ("HasTrackList", .boolean(false)),
                ("Identity", .string("Vicious SID Player")),
                // Wir spielen nur lokale Dateien, die uns die Kommandozeile
                // uebergibt: Der Desktop darf uns also nichts oeffnen lassen.
                ("SupportedUriSchemes", .stringArray([])),
                ("SupportedMimeTypes", .stringArray(["audio/prs.sid"]))
            ]

        case MPRIS.playerInterface:
            // Der Rohwert von `PlaybackState` IST schon die MPRIS-Schreibweise
            // ("Playing"/"Paused"/"Stopped") — genau dafuer ist er so gewaehlt.
            // Hier wird deshalb bewusst nichts uebersetzt.
            let canSwitch = controller.subtunesCount > 1
            return [
                ("PlaybackStatus", .string(controller.state.rawValue)),
                ("Metadata", metadata()),
                // In Mikrosekunden. Wir melden ehrlich 0 und `CanSeek = false`:
                // Der Emulator laeuft in Echtzeit und kann nicht springen, und der
                // Controller fuehrt keine Spielzeit. Ein Fortschrittsbalken, der
                // sich nicht bewegt, ist besser als einer, der luegt.
                ("Position", .int64(0)),
                ("Rate", .double(1.0)),
                ("MinimumRate", .double(1.0)),
                ("MaximumRate", .double(1.0)),
                // Fest auf voller Lautstaerke: Der Sink mischt nicht, das erledigt
                // der Desktop-Mixer (siehe PlayerController.init).
                ("Volume", .double(1.0)),
                // Vor/Zurueck sind Subtune-Wechsel — bei einer Datei mit nur einem
                // Subtune gibt es also nichts zu wechseln, und das Applet blendet
                // die Knoepfe passend aus.
                ("CanGoNext", .boolean(canSwitch)),
                ("CanGoPrevious", .boolean(canSwitch)),
                ("CanPlay", .boolean(true)),
                ("CanPause", .boolean(true)),
                ("CanSeek", .boolean(false)),
                // „Darf der Desktop uns ueberhaupt bedienen?" Ja — sonst waere das
                // hier alles umsonst. Ohne dieses Flag zeigen viele Applets nur
                // eine tote Anzeige ohne Knoepfe.
                ("CanControl", .boolean(true))
            ]

        default:
            return []
        }
    }

    /// Eine einzelne Property, oder `nil`, wenn es sie hier nicht gibt.
    private func property(interface: String, name: String) -> MPRISValue? {
        properties(of: interface).first { $0.0 == name }?.1
    }

    /// Die Metadaten des laufenden Stuecks als a{sv}.
    ///
    /// Nur die drei Felder, die wir wirklich haben. Erfundene Werte (Album,
    /// Laenge, Cover) waeren schlimmer als fehlende: Clients zeigen sie an, und
    /// niemand koennte erkennen, dass sie geraten sind.
    private func metadata() -> MPRISValue {
        let subtune = controller.currentSubtune
        let count = controller.subtunesCount

        // `mpris:trackid` ist Pflicht und muss ein gueltiger OBJEKTPFAD sein —
        // nicht bloss irgendein String. Erlaubt sind nur A–Z, a–z, 0–9 und `_`,
        // getrennt durch `/`; ein Bindestrich (wie in unserem Bus-Namen) waere
        // schon zu viel und liesse libdbus die Nachricht verweigern.
        //
        // Der Subtune steckt bewusst im Pfad: Fuer den Desktop ist jeder Subtune
        // ein eigener Titel, und an der geaenderten trackid erkennt er den Wechsel.
        let trackID = "/org/mpris/MediaPlayer2/vicious_sid/subtune\(subtune)"

        // Bei mehreren Subtunes gehoert die Nummer sichtbar in den Titel — sonst
        // stehen im Applet mehrere identische Eintraege hintereinander und niemand
        // weiss, wo im Stueck man ist.
        var title = controller.metadata.title
        if title.isEmpty { title = "Unbekannter Titel" }
        if count > 1 {
            title += " (Subtune \(subtune + 1)/\(count))"
        }

        // `xesam:artist` ist laut Spezifikation eine LISTE (ein Stueck kann mehrere
        // Urheber haben) — auch wenn wir immer nur einen Namen kennen. Ein leerer
        // Autor wird zur leeren Liste statt zu einem leeren Eintrag: Sonst zeigte
        // das Applet einen namenlosen Interpreten an.
        let author = controller.metadata.author
        let artists: [String] = author.isEmpty ? [] : [author]

        return .dictionary([
            ("mpris:trackid", .objectPath(trackID)),
            ("xesam:title", .string(title)),
            ("xesam:artist", .stringArray(artists))
        ])
    }

    // MARK: - Signal

    /// Sagt allen Interessierten, dass sich Zustand oder Titel geaendert haben.
    ///
    /// Ohne dieses Signal muesste das Applet staendig nachfragen — die meisten tun
    /// das nicht und zeigten dann fuer immer den Stand vom Verbindungsaufbau.
    ///
    /// Laeuft ausschliesslich auf dem Bus-Thread (siehe `markChanged`).
    private func emitPropertiesChanged(connection: OpaquePointer) {
        // Ein Signal hat keinen Empfaenger: Es traegt nur, WER (Objektpfad) unter
        // WELCHEM Interface WAS (Signalname) zu melden hat. Wer es hoeren will, hat
        // sich beim Bus dafuer angemeldet.
        guard let signal = dbus_message_new_signal(MPRIS.objectPath,
                                                   MPRIS.propertiesInterface,
                                                   "PropertiesChanged") else {
            return
        }
        defer { dbus_message_unref(signal) }

        var iter = DBusMessageIter()
        dbus_message_iter_init_append(signal, &iter)

        // Das Signal hat drei Argumente: (1) um welches Interface es geht,
        // (2) die neuen Werte, (3) die Namen der Werte, die man neu erfragen muss.
        MPRISServer.append(.string(MPRIS.playerInterface), to: &iter)

        // Nur, was sich wirklich aendern kann: der Zustand und — beim
        // Subtune-Wechsel — die Metadaten. Die ganzen `Can…`-Flags haengen allein
        // an der Subtune-Anzahl und stehen damit fuer die Lebensdauer des
        // Prozesses fest; sie mitzuschicken waere nur Laerm.
        MPRISServer.append(.dictionary([
            ("PlaybackStatus", .string(controller.state.rawValue)),
            ("Metadata", metadata())
        ]), to: &iter)

        // Leere Liste: Wir schicken alle geaenderten Werte gleich mit, es muss also
        // nichts nachgefragt werden.
        MPRISServer.append(.stringArray([]), to: &iter)

        dbus_connection_send(connection, signal, nil)
        // Sofort rausschicken statt auf die naechste Runde zu warten — sonst
        // huepfte die Anzeige im Applet spuerbar hinterher.
        dbus_connection_flush(connection)
    }

    // MARK: - Antworten verschicken

    /// Schickt die Antwort auf einen Methodenaufruf. `fill` haengt die
    /// Rueckgabewerte an; ohne `fill` ist es die leere „hat geklappt"-Antwort.
    ///
    /// Jeder Methodenaufruf braucht genau eine Antwort — entweder ein Ergebnis
    /// oder einen Fehler. Bleibt sie aus, wartet der Aufrufer bis in seinen
    /// Timeout (typisch 25 Sekunden) und haelt uns fuer haengengeblieben.
    @discardableResult
    private func reply(to message: OpaquePointer,
                       on connection: OpaquePointer,
                       fill: ((inout DBusMessageIter) -> Void)? = nil) -> DBusHandlerResult {
        // Der Aufrufer kann ausdruecklich sagen, dass er keine Antwort will
        // (typisch bei Medientasten: druecken und weitergehen). Dann waere eine
        // Antwort unerwuenschter Verkehr.
        guard dbus_message_get_no_reply(message) == 0 else {
            return DBUS_HANDLER_RESULT_HANDLED
        }
        guard let response = dbus_message_new_method_return(message) else {
            return DBUS_HANDLER_RESULT_HANDLED
        }
        // Wir haben die Nachricht erzeugt, also gehoert sie uns: `send` macht sich
        // seine eigene Kopie, unsere Referenz muessen wir wieder abgeben.
        defer { dbus_message_unref(response) }

        if let fill {
            var iter = DBusMessageIter()
            dbus_message_iter_init_append(response, &iter)
            fill(&iter)
        }

        dbus_connection_send(connection, response, nil)
        return DBUS_HANDLER_RESULT_HANDLED
    }

    /// Schickt eine Fehlerantwort. `name` ist ein D-Bus-Fehlername in
    /// Punktschreibweise — Clients werten ihn aus, `text` ist fuer Menschen.
    private func replyError(to message: OpaquePointer,
                            on connection: OpaquePointer,
                            name: String,
                            text: String) -> DBusHandlerResult {
        guard dbus_message_get_no_reply(message) == 0 else {
            return DBUS_HANDLER_RESULT_HANDLED
        }
        guard let response = dbus_message_new_error(message, name, text) else {
            return DBUS_HANDLER_RESULT_HANDLED
        }
        defer { dbus_message_unref(response) }
        dbus_connection_send(connection, response, nil)
        return DBUS_HANDLER_RESULT_HANDLED
    }

    // MARK: - Werte lesen und schreiben
    //
    // Ab hier wird es fummelig: libdbus baut Nachrichten ueber „Iteratoren", und
    // verschachtelte Werte brauchen fuer jede Ebene einen eigenen. Die eiserne
    // Regel lautet: Jedes `open_container` braucht sein `close_container`, und
    // zwischen den beiden wird ausschliesslich in den UNTER-Iterator geschrieben.
    // Wer das verwechselt, bekommt keine Compilerfehler, sondern eine kaputte
    // Nachricht oder eine Assertion aus libdbus.

    /// Liest einen String am aktuellen Stand des Iterators.
    /// `nil`, wenn dort gar kein String steht — dann ist der Aufruf fehlerhaft.
    private static func readString(_ iter: inout DBusMessageIter) -> String? {
        guard dbus_message_iter_get_arg_type(&iter) == dbusTypeString else {
            return nil
        }
        // `get_basic` schreibt bei einem String KEINE Kopie, sondern den Zeiger auf
        // den Text in der Nachricht — deshalb ein `char *` als Ziel und nicht ein
        // Zeichenpuffer. Der Text lebt so lange wie die Nachricht; wir bauen uns
        // daraus sofort einen eigenen Swift-String.
        var raw: UnsafePointer<CChar>?
        dbus_message_iter_get_basic(&iter, &raw)
        guard let raw else { return nil }
        return String(cString: raw)
    }

    /// Haengt einen String (oder Objektpfad) an.
    ///
    /// Der Umweg ueber zwei Ebenen ist kein Zufall: `append_basic` will bei jedem
    /// Typ die ADRESSE des Wertes. Bei einem String ist der Wert selbst schon ein
    /// Zeiger, also braucht libdbus einen Zeiger auf den Zeiger.
    private static func appendString(_ text: String, type: Int32, to iter: inout DBusMessageIter) {
        text.withCString { raw in
            var pointer: UnsafePointer<CChar>? = raw
            _ = dbus_message_iter_append_basic(&iter, type, &pointer)
        }
    }

    /// Haengt einen Wert in seiner natuerlichen Form an (ohne Variante drumherum).
    private static func append(_ value: MPRISValue, to iter: inout DBusMessageIter) {
        switch value {
        case .boolean(let flag):
            // D-Bus kennt keinen 1-Byte-Bool: Ein Boolean ist auf dem Draht ein
            // 32-Bit-Wort, das nur 0 oder 1 sein darf. `dbus_bool_t` ist genau das.
            var raw = dbus_bool_t(flag ? 1 : 0)
            _ = dbus_message_iter_append_basic(&iter, dbusTypeBoolean, &raw)

        case .string(let text):
            appendString(text, type: dbusTypeString, to: &iter)

        case .objectPath(let path):
            appendString(path, type: dbusTypeObjectPath, to: &iter)

        case .double(let number):
            var raw = number
            _ = dbus_message_iter_append_basic(&iter, dbusTypeDouble, &raw)

        case .int64(let number):
            var raw = number
            _ = dbus_message_iter_append_basic(&iter, dbusTypeInt64, &raw)

        case .stringArray(let items):
            // Ein Array kuendigt an, was drinsteckt ("s"), und bekommt dafuer einen
            // eigenen Iterator. Auch ein LEERES Array braucht diese beiden
            // Aufrufe — sonst fehlte in der Nachricht schlicht ein Argument.
            var array = DBusMessageIter()
            _ = dbus_message_iter_open_container(&iter, dbusTypeArray, "s", &array)
            for item in items {
                appendString(item, type: dbusTypeString, to: &array)
            }
            _ = dbus_message_iter_close_container(&iter, &array)

        case .dictionary(let entries):
            // a{sv} — drei Ebenen tief, und jede will einzeln geoeffnet werden:
            //
            //   Array "{sv}"                    ← die Landkarte
            //     └ DICT_ENTRY (ohne Signatur)  ← ein Paar
            //         ├ String                  ← der Schluessel
            //         └ VARIANT                 ← der Wert, in seiner Huelle
            //
            // Zwei Stolpersteine sitzen genau hier:
            // * Die Signatur des Arrays ist "{sv}" mit geschweiften Klammern, der
            //   TYPCODE des Eintrags dagegen ist 'e' (siehe oben bei den
            //   Konstanten). Zwei Schreibweisen fuer dieselbe Sache.
            // * Ein DICT_ENTRY bekommt KEINE Signatur (nil): Sie steht schon in der
            //   des umgebenden Arrays. Wer hier trotzdem etwas mitgibt, faellt in
            //   eine Assertion.
            var array = DBusMessageIter()
            _ = dbus_message_iter_open_container(&iter, dbusTypeArray, "{sv}", &array)
            for (key, entryValue) in entries {
                var entry = DBusMessageIter()
                _ = dbus_message_iter_open_container(&array, dbusTypeDictEntry, nil, &entry)
                appendString(key, type: dbusTypeString, to: &entry)
                appendVariant(entryValue, to: &entry)
                _ = dbus_message_iter_close_container(&array, &entry)
            }
            _ = dbus_message_iter_close_container(&iter, &array)
        }
    }

    /// Haengt einen Wert als Variante an.
    ///
    /// Eine **Variante** ist eine Huelle, die ihren Inhalt selbst beschreibt: „hier
    /// kommt ein String" gefolgt vom String. D-Bus ist streng typisiert, eine
    /// Landkarte mit gemischten Werten (Titel als String, Interpreten als Liste)
    /// waere sonst gar nicht ausdrueckbar. Der Preis: JEDER Wert braucht seine
    /// eigene Huelle — vergessene Varianten sind der haeufigste Fehler beim Bauen
    /// von a{sv}.
    private static func appendVariant(_ value: MPRISValue, to iter: inout DBusMessageIter) {
        var variant = DBusMessageIter()
        _ = dbus_message_iter_open_container(&iter, dbusTypeVariant, value.signature, &variant)
        append(value, to: &variant)
        _ = dbus_message_iter_close_container(&iter, &variant)
    }

    /// Holt den Klartext aus einem `DBusError`.
    private static func text(of error: inout DBusError) -> String {
        guard dbus_error_is_set(&error) != 0, let message = error.message else {
            return "kein Grund angegeben"
        }
        return String(cString: message)
    }

    // MARK: - Selbstbeschreibung

    /// Die Antwort auf `Introspect()`: Was dieses Objekt kann, als XML.
    ///
    /// Das ist der Zettel, den ein Client liest, bevor er uns benutzt. Er muss zu
    /// dem passen, was `handle(connection:message:)` und `properties(of:)`
    /// tatsaechlich tun — steht hier etwas, das es nicht gibt, laeuft der Client in
    /// einen Fehler; fehlt hier etwas, benutzt er es erst gar nicht. Bei
    /// Aenderungen also immer beide Stellen anfassen.
    ///
    /// Die Typkuerzel sind dieselben wie ueberall in D-Bus: s = String, b =
    /// Boolean, d = Double, x = Int64, o = Objektpfad, v = Variante, as = Liste
    /// von Strings, a{sv} = Landkarte String → beliebig.
    private static let introspectionXML = """
    <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    <node>
      <interface name="org.freedesktop.DBus.Introspectable">
        <method name="Introspect">
          <arg name="xml_data" type="s" direction="out"/>
        </method>
      </interface>
      <interface name="org.freedesktop.DBus.Properties">
        <method name="Get">
          <arg name="interface_name" type="s" direction="in"/>
          <arg name="property_name" type="s" direction="in"/>
          <arg name="value" type="v" direction="out"/>
        </method>
        <method name="GetAll">
          <arg name="interface_name" type="s" direction="in"/>
          <arg name="properties" type="a{sv}" direction="out"/>
        </method>
        <method name="Set">
          <arg name="interface_name" type="s" direction="in"/>
          <arg name="property_name" type="s" direction="in"/>
          <arg name="value" type="v" direction="in"/>
        </method>
        <signal name="PropertiesChanged">
          <arg name="interface_name" type="s"/>
          <arg name="changed_properties" type="a{sv}"/>
          <arg name="invalidated_properties" type="as"/>
        </signal>
      </interface>
      <interface name="org.mpris.MediaPlayer2">
        <method name="Raise"/>
        <method name="Quit"/>
        <property name="CanQuit" type="b" access="read"/>
        <property name="CanRaise" type="b" access="read"/>
        <property name="HasTrackList" type="b" access="read"/>
        <property name="Identity" type="s" access="read"/>
        <property name="SupportedUriSchemes" type="as" access="read"/>
        <property name="SupportedMimeTypes" type="as" access="read"/>
      </interface>
      <interface name="org.mpris.MediaPlayer2.Player">
        <method name="Next"/>
        <method name="Previous"/>
        <method name="Pause"/>
        <method name="PlayPause"/>
        <method name="Stop"/>
        <method name="Play"/>
        <property name="PlaybackStatus" type="s" access="read"/>
        <property name="Metadata" type="a{sv}" access="read"/>
        <property name="Position" type="x" access="read"/>
        <property name="Rate" type="d" access="read"/>
        <property name="MinimumRate" type="d" access="read"/>
        <property name="MaximumRate" type="d" access="read"/>
        <property name="Volume" type="d" access="read"/>
        <property name="CanGoNext" type="b" access="read"/>
        <property name="CanGoPrevious" type="b" access="read"/>
        <property name="CanPlay" type="b" access="read"/>
        <property name="CanPause" type="b" access="read"/>
        <property name="CanSeek" type="b" access="read"/>
        <property name="CanControl" type="b" access="read"/>
      </interface>
    </node>
    """
}
#endif
