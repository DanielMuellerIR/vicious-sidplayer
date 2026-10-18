# SID format compatibility

Applies to Vicious SID Player 1.9.44. Header interpretation follows the [HVSC SID specification dated 2026-10-09](https://www.hvsc.c64.org/download/C64Music/DOCUMENTS/SID_file_format.txt) and the [Unicode Windows-1252 mapping](https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/WINDOWS/CP1252.TXT).

| Feature | macOS / iPhone | HTML5 |
| --- | --- | --- |
| PSID v1–v4 | Supported within the emulator's existing limits | Same header rules |
| PSID v5 | Supported with up to three SID chips | Same header rules |
| RSID v2–v5 machine code | Limited IRQ-based support; not full C64 emulation | Same limitation |
| Windows-1252 metadata | All supported versions | Same decoding |
| V5 shared metadata area | Three variable strings in 96 bytes, with the required fixed-field fallback | Same decoding |
| V3/v4 per-chip models | Preserved | Preserved |
| V5 multi-SID configurations | All seven layouts, including a valid custom second-chip start; one common model | Same configurations and model |
| Audio channels | One SID centered; multi-SID stereo | Existing mono mix |
| V5 spatial hints | Existing native pan layout | Existing mono output |
| V5 positive embedded lengths | Playback, search, audit and export | Playback, A/B bounds and audit |
| MUS, BASIC-start RSID, FM OPL, more than three SIDs | Explicit unsupported error | Explicit unsupported error |

The v5 specification permits output fallback when spatial hints cannot be represented. The player therefore retains its established output layout. Model overrides still apply globally.

A valid v5 length trailer is metadata and is never loaded into C64 RAM. Zero means unknown. Native duration priority is personal end time → HVSC → positive embedded length → computed cache → six-minute fallback. HTML5 uses positive embedded lengths before its six-minute fallback; it does not add an HVSC database or native export features.

RSID's reserved load, play and speed fields are checked, along with effective load/init bounds. Simple installed IRQ routines start with the specified CIA timer even though the header speed bits are zero. Tunes needing BASIC/Kernal ROM execution or unsupported C64 hardware remain outside the emulator's capabilities; a valid header alone cannot establish playback compatibility. PSID v1 and PlaySID-specific files repeat the 32 speed bits for subtunes above 32; other PSID versions keep the last bit.

Malformed v5 address layouts, invalid BCD lengths, incomplete headers and initialization outside the loaded program receive concrete errors. Legacy padded payloads retain the existing safe RAM truncation diagnostic. Invalid additional-chip address bytes in v3/v4 mean no chip in that slot; two slots cannot claim the same address.

Undefined Windows-1252 byte values remain visible as replacement characters. Metadata cache version 2 forces old derived text/model records to be read again; the music index, track identities and personal data are retained.

See [validation and remaining limits](validation-1.9.44.md). No SID music files are included in the application or test suite.
