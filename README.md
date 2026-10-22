# CadSHAPE Mål – iPhone-appen

Mål et hull i vegg eller tak med iPhone-kameraet og LiDAR, og få det tegnet rett inn i
[CadSHAPE](#bruk) på PC-en – som lokk, plugg, dekkplate eller bare formen.

- **Kanten** på hullet finnes i kamerabildet med sub-piksel-nøyaktighet (eller i LiDAR-dybden
  når hullet er like lyst som veggen).
- **Flaten** rundt hullet – avstand og vinkel – måles med LiDAR (hundrevis av punkter, robust
  plan-tilpasning), så det spiller ingen rolle om du står litt på skrå.
- **Formen** (rund, firkantet med runde hjørner eller fri) tilpasses av CadSHAPE på PC-en, med
  samme kode som nettsiden, og vises der mens du måler.
- Ingen konto, ingen sky: appen snakker bare med din egen PC på samme wifi.

Krever iPhone med LiDAR (12 Pro / 13 Pro / 14 Pro / 15 Pro / 16 Pro …) for best resultat. Uten
LiDAR brukes ARKit sitt anslag av flaten (grovere).

## Installere (gratis, med din egen Apple-ID)

Appen ligger ikke i App Store. Den bygges automatisk her på GitHub og installeres med
**Sideloadly** (Windows/Mac) eller **SideStore**, som signerer den med din egen Apple-ID.
Apple-ID-en og passordet ditt skrives bare inn i Sideloadly/SideStore – aldri her.

1. Last ned **CadshapeMaal.ipa** fra [Releases → latest](../../releases/tag/latest).
2. **Sideloadly** på PC-en (sideloadly.io). På Windows trenger den iTunes og iCloud fra
   Apples nettside (ikke Microsoft Store-versjonene) – Sideloadly sier fra hvis noe mangler.
3. Koble iPhone til PC-en med kabel og trykk «Stol på» på telefonen.
4. Dra IPA-filen inn i Sideloadly, skriv inn Apple-ID-en din og trykk **Start**. Klager den på
   «bundle ID», slå på *Change bundle ID* under *Advanced options* og prøv igjen.
5. På iPhone:
   - **Innstillinger → Personvern og sikkerhet → Utviklermodus → på** (telefonen starter på nytt).
   - **Innstillinger → Generelt → VPN og enhetsadministrasjon →** din Apple-ID → **Stol på**.
6. Åpne **CadSHAPE Mål**. Tillat kamera og «enheter i lokalt nettverk».

**Gratis Apple-ID:** appen må fornyes hver 7. dag. Kjør Sideloadly på nytt med samme IPA
(innstillingene beholdes), eller bruk **SideStore**, som fornyer over wifi uten PC.
Du kan ha inntil 3 slike apper samtidig.

## Bruk

1. Start CadSHAPE på PC-en med **START_CADSHAPE_MOBIL.bat**.
2. I CadSHAPE: **Fil → Mål med telefonen / åpne på mobil**.
3. Åpne appen og sikt på QR-koden – den kobler seg til av seg selv (husker PC-en senere).
4. Sikt krysset midt på hullet, 30–80 cm unna. Hold stille til streken blir **grønn**.
5. **Lås målet** → velg *Lokk*, *Plugg*, *Plate* eller *Form*, juster mål, eventuelt
   standardstørrelse (hullsag/downlight) → **Lag i CadSHAPE**.

## Slik er appen bygd

| Mappe | Innhold |
| --- | --- |
| `HoleKit/` | Målematematikken uten Apple-UI: hullfinner, LiDAR-plan (RANSAC + minste kvadrater), stråle → plan → mm, sirkeltilpasning. Testes med `swift test`. |
| `CadshapeMaal/` | SwiftUI-appen: ARKit (kamera, LiDAR, linse), QR-tilkobling, tegning over kamerabildet, kontakt med CadSHAPE. |
| `project.yml` | Xcode-prosjektet (XcodeGen). |
| `.github/workflows/build.yml` | Bygger på en Mac hos GitHub: tester HoleKit, bygger usignert IPA og legger den på release «latest». |

Bygge selv på en Mac: `brew install xcodegen && xcodegen generate && open CadshapeMaal.xcodeproj`.

Appen sender omrisset av hullet (mm) til `POST /api/live/scan` på PC-en, med nøkkelen fra
QR-koden. CadSHAPE sitt eget HTTPS-sertifikat godtas bare for den PC-en du koblet til, og
huskes etter første kontakt.
