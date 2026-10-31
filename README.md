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
(innstillingene beholdes), eller bruk **SideStore**, som fornyer og oppdaterer over wifi uten PC.
Du kan ha inntil 3 slike apper samtidig (SideStore teller som én).

### Oppdatere over wifi med SideStore

Hvert bygg her legger også en SideStore-kilde på
`https://raw.githubusercontent.com/Pikacha/cadshape-maal-ios/source/sidestore.json`
(versjon, byggnummer, størrelse og tillatelser leses fra selve IPA-en). Når SideStore ser et
nytt byggnummer, dukker **Oppdater** opp på appen.

Én gang, med kabel:

1. På PC-en: **iTunes** (fra Apple, ikke Microsoft Store) og **iloader** (iloader.site).
2. På iPhone: kode på skjermen, og **Utviklermodus på** (Personvern og sikkerhet).
3. Koble til med kabel, åpne iloader, logg inn med Apple-ID-en og velg **Install SideStore**.
   iloader legger også inn sammenkoblingsfilen (pairing file) SideStore trenger.
4. På iPhone: **Stol på** Apple-ID-en under *VPN og enhetsadministrasjon*, installer
   **LocalDevVPN** fra App Store og slå den på.
5. Åpne SideStore, logg inn med samme Apple-ID. **Kilder → +** → lim inn adressen over.
6. Bla til CadSHAPE Mål → **Installer**. Slett gjerne den gamle Sideloadly-kopien etterpå
   (SideStore gir appen sitt eget bundle-ID, så de blir to apper). Logg inn på nett /
   skann QR på nytt i den nye.

Etterpå, uten PC: slå på LocalDevVPN, åpne SideStore → **Mine apper** → **Oppdater** når det
er en ny versjon, og **Oppdater alle** (refresh) minst hver 7. dag. Wifi må være på.

## Bruk

1. Koble til CadSHAPE på én av to måter:
   - **På nett:** innstillinger → *CadSHAPE på nett* → adressen (f.eks. `kloki.no/cadshape`) og
     passordet. Virker hvor som helst; delene lages i CadSHAPE som er åpent i en nettleser.
   - **PC-en på samme wifi:** start CadSHAPE med **START_CADSHAPE_MOBIL.bat**, Fil → **Mål med
     telefonen**, og sikt på QR-koden.
2. Sikt krysset midt på hullet, mest mulig rett på og med en skarp, godt belyst kant. Små hull
   må fylle nok av bildet; gå nærmere hvis appen ber om det. Automatisk låsing krever stødig
   mål, normalt kameraspôr og tilstrekkelig støtte i LiDAR-flaten og bildekanten. En kant fra
   bare LiDAR låses manuelt. «Anslått avvik» er en konservativ screening, ikke et kalibrert
   konfidensintervall eller en garanti for presspasning.
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
6. **Ting** (krever LiDAR): legg tingen på et ryddig bord og sikt på den. Kanten finnes med LiDAR
   og gjøres skarpere med kamerabildet (± 0,7 mm). *Legg til en ting til* samler flere i samme
   *brett* eller *Gridfinity-boks*, med lommer i tingenes form og et grep for fingeren.
   **Gridfinity** for en skuff (fra *Boks*) kan også få bokser som fyller den, med stablekant.
7. **Rør** (krever LiDAR): sikt på et rør, en stang eller en slange fra siden. Du får diameteren og
   nærmeste standard, og velger *rørklemme*, *endelokk* eller *overgang* (mål da den andre også).
8. **Spalte** (krever LiDAR): sikt på den ene flaten og trykk *Flate 1*, så den andre og *Flate 2*.
   Du får avstanden og vinkelen, og velger *mellomlegg*, *kile* eller et *prøvesett* med fem
   tykkelser.
9. Alt du måler lagres på telefonen med bilde (skuffen øverst til høyre). Er CadSHAPE ikke
   åpent, kan målingen sendes senere. Bildet vises også i CadSHAPE ved siden av delen.

## Kontroll av små hull og presspasning

- Etter låsing: åpne **Kontrollmål for hullet** og oppgi hullets **innvendige diameter** med
  punktum eller komma. Bruk målet bare når du faktisk har kontrollert hullet. Ikke bruk den
  printede plastringens innvendige diameter: det er ringens **utvendige** mål som skal passe.
- Kontrollmålet endrer bare den aktuelle delen; det lagres ikke som en global LiDAR-korreksjon.
  Et grovt linjalmål er ingen kalibrering av telefonen. Test en kort passformring før et stort lokk.
- Med 0,4 mm klaring per side gir for eksempel et hull på Ø23,0 mm en krage med ytre Ø22,2 mm.
- **Del måledata** deler bare tall fra målingen: avstand, vinkel, kantoppløsning og støtte i
  veggflaten. Ingen bilde- eller tilkoblingsdata følger med. Dette hjelper ved senere feil passform.

Kamera og LiDAR bruker nå primært samme bildes `sceneDepth`. Apples `smoothedSceneDepth`
er et gjennomsnitt over flere bilder og brukes bare som en markert, grovere reserve.
Se [sceneDepth](https://developer.apple.com/documentation/arkit/arframe/scenedepth) og
[smoothedSceneDepth](https://developer.apple.com/documentation/arkit/arframe/smoothedscenedepth).
En tett punktsky alene er ikke nok: minst 60 % av prøvene må støtte samme plan, og punktene må
dekke to retninger. Lav oppløsning og repeterbare feil blir ikke gjort nøyaktige av flere like bilder.

Regresjonstestene omfatter nå hull rundt 23 mm, skrå flater, tilfeldige og nesten linjeformede
dybdepunkter, grove LiDAR-kanter og kontrollmål. Syntetiske tester erstatter ikke en fysisk
kontrollmåling av telefon, hull og utskrift. Xcode-bygg og installasjon av ny IPA kreves før
en allerede installert iPhone-app bruker endringene.

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
