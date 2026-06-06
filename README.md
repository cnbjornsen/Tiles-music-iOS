# 🎵 Tiles Music

Et "Magic Tiles"-lignende rytmespil til **iOS og iPadOS**, bygget i SwiftUI.
Log ind med Spotify, vælg en sang fra dit bibliotek, og ram tilene i takt med musikken.

> **Sprog:** Appens UI og kode-kommentarer er på dansk.

---

## ✨ Hvad appen kan

- **Login med Spotify** via sikkert OAuth 2.0 PKCE-flow (ingen client secret i appen).
- Browse dine **mest spillede sange, gemte sange og playlister**.
- Vælg en sang og en **sværhedsgrad** (Let / Mellem / Svær).
- Spil et **4-baners tile-spil** hvor tilene falder i takt med sangens tempo (BPM).
- **Tap-tiles og hold-tiles** (lange toner der skal holdes nede).
- **Point, combo, liv** og resultatskærm.
- **Lokale rekorder** pr. sang og sværhedsgrad (gemmes på enheden).
- **Afspilning af den rigtige Spotify-sang** under spillet via Spotify App Remote (kræver Premium – se nedenfor).

---

## ⚠️ Vigtige begrænsninger (læs her)

Spotifys API tillader **ikke** at man frit synkroniserer et spil til den rå lyd:

1. **Tempo i stedet for noder.** Vi kan ikke få præcise node-timings. Tilene
   genereres derfor proceduremæssigt ud fra sangens **BPM** (tempo). Det er rytmisk,
   men ikke 1:1 med melodien. Tempo hentes fra Spotifys `audio-features` – og hvis
   Spotify har spærret det endpoint for din app, falder spillet automatisk tilbage
   til et standardtempo pr. sværhedsgrad.
2. **Afspilning kræver Premium + Spotify-appen.** Lyd afspilles gennem Spotifys
   officielle iOS SDK (App Remote), som styrer Spotify-appen på enheden. Det
   kræver et **Spotify Premium**-abonnement og at **Spotify-appen er installeret**.
3. **Gratis installation på iPad** med et gratis Apple-ID virker, men appen skal
   **gen-signeres ca. hver 7. dag** i Xcode. Med et betalt Developer Program ($99/år)
   holder den i et år.

Hvis du **ikke** tilføjer Spotify-frameworket, kompilerer og kører appen alligevel –
du kan spille spillet, men uden Spotify-lyd (kun klik-feedback). Koden bruger
`#if canImport(SpotifyiOS)`, så den rigtige afspilning aktiveres automatisk når
frameworket er på plads.

---

## 🚀 Kom i gang

### 1. Opret en Spotify-app
1. Gå til <https://developer.spotify.com/dashboard> og log ind.
2. Klik **Create app**. Navn: fx `Tiles Music`.
3. Tilføj denne **Redirect URI** (præcist):
   ```
   tilesmusic://callback
   ```
4. Under indstillinger: aktivér **iOS** og indtast dit **Bundle ID**
   (standard: `dk.grafikr.TilesMusic`).
5. Kopiér **Client ID**.

### 2. Indsæt dit Client ID
Åbn `TilesMusic/Config/SpotifyConfig.swift` og erstat:
```swift
static let clientID = "DIT_SPOTIFY_CLIENT_ID"
```
med dit rigtige Client ID.

### 3. Åbn projektet i Xcode
```
open TilesMusic.xcodeproj
```
- Vælg target **TilesMusic** → fanen **Signing & Capabilities**.
- Vælg dit **Team** (dit gratis Apple-ID virker).
- Ret evt. **Bundle Identifier** hvis `dk.grafikr.TilesMusic` allerede er taget –
  husk så at opdatere det samme sted i Spotify-dashboardet.

### 4. (Valgfrit men anbefalet) Tilføj Spotify iOS SDK for rigtig lyd
1. Hent **SpotifyiOS.xcframework** fra
   <https://github.com/spotify/ios-sdk/releases>.
2. Træk `SpotifyiOS.xcframework` ind i projektet i Xcode.
3. Under target → **General → Frameworks, Libraries, and Embedded Content**:
   sæt den til **Embed & Sign**.
4. Byg igen. `#if canImport(SpotifyiOS)` aktiverer nu rigtig afspilning.

### 5. Kør på din iPad
- Forbind din iPad via kabel (eller trådløst), vælg den som destination.
- Tryk **Run** (⌘R).
- Første gang skal du på iPad'en godkende udvikleren under
  **Indstillinger → Generelt → VPN og enhedsadministration**.

---

## 🗂 Projektstruktur

```
TilesMusic/
├── TilesMusicApp.swift          # App-entry, håndterer callback-URL
├── Config/
│   └── SpotifyConfig.swift       # ← indsæt dit Client ID her
├── Models/
│   ├── Track.swift               # Sang fra Spotify
│   ├── Playlist.swift            # Playliste fra biblioteket
│   └── Beatmap.swift             # Tile-model + procedural generator (BPM)
├── Services/
│   ├── Keychain.swift            # Sikker token-opbevaring
│   ├── SpotifyAuthManager.swift  # OAuth PKCE login + token-fornyelse
│   ├── SpotifyAPI.swift          # Web API: profil, playlister, sange, tempo
│   ├── PlaybackController.swift  # Spotify App Remote (afspilning)
│   └── SoundEngine.swift         # Klik-lyd + haptik som hit-feedback
├── Game/
│   └── GameEngine.swift          # Spil-loop, point, combo, liv (CADisplayLink)
└── Views/
    ├── RootView.swift            # Login vs. bibliotek
    ├── LoginView.swift
    ├── LibraryView.swift         # Browse Spotify-biblioteket
    ├── GameSetupView.swift       # Vælg sværhedsgrad, start
    ├── GameView.swift            # Selve spillet (Canvas)
    └── ResultView.swift          # Resultatskærm
```

---

## 🎮 Sådan spiller man
Tiles falder ned i fire baner. Tryk i den rigtige bane lige når en tile rammer
den hvide linje. Jo mere præcist, jo flere point – og en høj **combo** giver bonus.

- **Tap-tiles:** et hurtigt tryk når tilen rammer linjen.
- **Hold-tiles:** lange, glødende bjælker – tryk og **hold fingeren nede** indtil
  bjælken er "spist" af hit-linjen. Slipper du for tidligt, mister du et liv.

Du har 5 liv; misser du for mange tiles, er det game over. Din bedste score
gemmes lokalt pr. sang og sværhedsgrad.

---

## ✨ Animationer (hvad du ser på skærmen)
- **Faldende tiles** glider jævnt nedad i baneflens farve (CADisplayLink → 60/120 fps).
- **Hit-pop:** ved hvert ramt tile vokser en lysende ring ud fra hit-linjen og fader –
  hvid ved "Perfekt", banens farve ved "Godt".
- **Hold-glød:** mens du holder, lyser bjælken hvidt og gløder, og halen skrumper
  ned mod linjen indtil tonen er færdig.
- **Bane-glød:** banen lyser blødt op så længe en finger holder den nede.
- **Score** ruller med en tal-animation; **combo** giver et lille "pop"-hop hver gang den stiger.
- **Miss:** en rød kant blinker kort rundt om skærmen, og et hjerte forsvinder med et bounce.
- **Dom-tekst** ("Perfekt!/Godt/Miss") popper ind skaleret og fader ud igen.
- **Resultatskærm:** "Ny rekord!"-badge springer ind med en fjeder-animation.

---

## 🛠 Idéer til videreudvikling
- Bedre synkronisering ved at læse den faktiske afspilningsposition fra App Remote.
- Partikel-effekter / "shake" ved høj combo.
- To-fingers-tiles (tryk to baner samtidig).
- Online leaderboard via Game Center.
- Egne sange/lydfiler som alternativ til Spotify.
