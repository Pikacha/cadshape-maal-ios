# CadSHAPE Mål – iPhone-appen

Mål et hull i vegg eller tak med iPhone-kameraet og LiDAR, og få det tegnet rett inn i
[CadSHAPE](#bruk) på PC-en – som lokk, plugg, dekkplate eller bare formen.

- **Kanten** på hullet finnes i kamerabildet med sub-piksel-nøyaktighet (eller i LiDAR-dybden
  når hullet er like lyst som veggen).
- **Flaten** rundt hullet – avstand og vinkel – måles med LiDAR (hundrevis av punkter, robust
  plan-tilpasning), så det spiller ingen rolle om du står litt på skrå.
- **Formen** (rund, firkantet med runde hjørner eller fri) tilpasses av CadSHAPE på PC-en, med
  samme kode som nettsiden, og vises der mens du måler.
- Ingen sky utenom din egen: appen snakker med PC-en på samme wifi, eller med din egen CadSHAPE på nett.

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

1. Koble til CadSHAPE på én av to måter:
   - **På nett:** innstillinger → *CadSHAPE på nett* → adressen (f.eks. `kloki.no/cadshape`) og
     passordet. Virker hvor som helst; delene lages i CadSHAPE som er åpent i en nettleser.
   - **PC-en på samme wifi:** start CadSHAPE med **START_CADSHAPE_MOBIL.bat**, Fil → **Mål med
     telefonen**, og sikt på QR-koden.
2. Sikt krysset midt på hullet, 30–80 cm unna. Når målet har vært stødig et sekund, **låses det
   av seg selv** (kan slås av i innstillingene). ± viser hvor sikkert målet er.
3. Velg *Lokk*, *Plugg*, *Plate* eller *Form*. Har LiDAR sett bunnen av hullet, kan dybden
   brukes med ett trykk. Tallene ligger under *Juster mål* → **Lag i CadSHAPE**.
4. **Hullmønster** (skruehull i en brakett, et kretskort …): velg *Hullmønster*, sikt på hullene
   ett for ett – hvert hull legges til når det er stødig og får et nummer i bildet – og trykk
   *Ferdig*. Du får en plate med hullene på riktig sted, eller bare hullene.
5. **Inni boks** (krever LiDAR): hold telefonen over en boks eller skuff og sikt krysset på bunnen.
   Appen samler LiDAR-punktene fra flere bilder og finner bunnen, de fire veggene (de lyser grønt
   når de er sett) og kanten øverst – innvendig bredde, lengde, høyde og veggtykkelse. Velg
   *Skillevegger med spor* (skyves i kryss, printes flatt), *Rutenett*, *Innsats*, *Gridfinity*-
   bunnplate eller *Lokk*, og hvor mange rom. Store ting deles opp så de passer på platen.
   Uten LiDAR, eller målt med tommestokk: *Skriv inn*.
6. **Gjenstand** (krever LiDAR): legg tingen på et ryddig bord og sikt på den. Du får fotavtrykket
   og høyden, og et *brett* eller en *Gridfinity-boks* med en lomme i tingens form og et grep.
7. Alt du måler lagres på telefonen med bilde (skuffen øverst til høyre). Er CadSHAPE ikke
   åpent, kan målingen sendes senere. Bildet vises også i CadSHAPE ved siden av delen.

## Slik er appen bygd

| Mappe | Innhold |
| --- | --- |
| `HoleKit/` | Målematematikken uten Apple-UI: hullfinner, LiDAR-plan (RANSAC + minste kvadrater), stråle → plan → mm, sirkeltilpasning, boks og gjenstand fra punktskyen (`Box.swift`, port av `src/scan/vision/box.ts`). Testes med `swift test`. |
| `CadshapeMaal/` | SwiftUI-appen: ARKit (kamera, LiDAR, linse), QR-tilkobling, tegning over kamerabildet, kontakt med CadSHAPE. |
| `project.yml` | Xcode-prosjektet (XcodeGen). |
| `.github/workflows/build.yml` | Bygger på en Mac hos GitHub: tester HoleKit, bygger usignert IPA og legger den på release «latest». |

Bygge selv på en Mac: `brew install xcodegen && xcodegen generate && open CadshapeMaal.xcodeproj`.

Appen sender omrisset av hullet (mm) til `POST /api/live/scan` på PC-en, med nøkkelen fra
QR-koden. CadSHAPE sitt eget HTTPS-sertifikat godtas bare for den PC-en du koblet til, og
huskes etter første kontakt.
