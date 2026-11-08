# Publishing on the App Store as Antenna (iPhone, iPad and Mac)

On the App Store the app is called **Antenna** (two other IPTV apps already use "Tuner" there, and "Tuner: IPTV
Player" is taken). The store builds show that name everywhere (`Distribution.appName`, `CFBundleDisplayName`); the
code, repository, data folders and the GitHub Mac app stay "Tuner".

What's already set up in the repo, what you do in App Store Connect, and the text to paste.

There are three builds of the same code:

| Build | How it's made | Where it goes |
|---|---|---|
| iPhone/iPad app | `iOS/scripts/archive-appstore.sh` (scheme `TunerIOS`) | App Store |
| Mac App Store app | `PLATFORM=mac iOS/scripts/archive-appstore.sh` (scheme `TunerMac`) | Mac App Store |
| GitHub Mac app | `scripts/release.sh` | GitHub Releases (Sparkle updates), as before |

The two store apps share the bundle ID **`app.tuner.player`**, so they are one product in App Store Connect
(**Universal Purchase**): one listing, and once you charge, one purchase unlocks iPhone, iPad and Mac. The GitHub
Mac app keeps `app.tuner.macos` and its own library, so the two Mac apps can be installed side by side.

**What the Mac App Store app leaves out** (the sandbox doesn't allow running Homebrew programs): recording and the
AirPlay converter for MKV/TS (AirPlay still works for HLS/MP4; Screen Mirroring for the rest). mpv is built in, so
nothing needs installing. Downloads go to `~/Movies/Antenna Downloads` (fixed), and iCloud sync uses a folder you pick
once, as on iPhone.

## Already prepared

- **Contentless:** the app ships with no playlists, channels or logos (the iptv-org "Try Free Channels" button is
  gone). About says the user is responsible for what their playlists contain.
- **Licences:** both store apps use MPVKit's **LGPL** build (the GPL one can't go through the App Store), linked
  into the app. Settings → About lists every bundled library with its licence, includes the LGPL 2.1 text and
  links to Tuner's source. Tuner's own code is under the PolyForm Noncommercial License (`LICENSE.md`): anyone can read
  and rebuild it, but only you can sell it.
- **Mac sandbox:** the `TunerMac` target builds with `TUNER_APP_STORE` (no Sparkle, recording or AirPlay converter;
  mpv linked in) and these entitlements: App Sandbox, outgoing network, user-selected files, app-scoped bookmarks and
  the Movies folder (written by XcodeGen from `iOS/project.yml` into `AppStore/Mac/Tuner.entitlements`).
- **Privacy manifest:** `iOS/Resources/PrivacyInfo.xcprivacy` (in both store apps) (no tracking, no data collected; reasons for
  UserDefaults, file timestamps and disk space).
- **Export compliance:** `ITSAppUsesNonExemptEncryption = NO` (standard HTTPS and hashing only).
- **No service names in the UI:** the Top 10 rows read "This week in Egypt"; only the settings footer names the source.
- **Build and upload:** `iOS/scripts/archive-appstore.sh` (version = `VERSION`, build = commit count).
- **Review playlist:** [`review-playlist.m3u`](review-playlist.m3u) (Apple's HLS samples, a test live stream and
  Blender CC-BY films; checked to play on 2026-11-08). Privacy policy: [`privacy.md`](privacy.md).

## Steps

1. **Bundle ID.** developer.apple.com → Certificates, IDs & Profiles → Identifiers → **+** → App IDs → App →
   Explicit Bundle ID `app.tuner.player`. No extra capabilities are needed (iCloud sync uses a folder the user picks,
   not CloudKit; the Mac sandbox needs no registered capabilities).
2. **Signing.** In `iOS/Config/Local.xcconfig` set `DEVELOPMENT_TEAM` to your **paid** team ID (leave
   `TUNER_BUNDLE_ID` as it is: the archive script uses `app.tuner.player`). Sign in to that team in Xcode →
   Settings → Accounts.
3. **App Store Connect → Apps → + → New App:** tick **iOS and macOS**, name `Antenna: IPTV Player`, primary language English,
   bundle ID `app.tuner.player`, SKU `tuner`, full access. (If you created it for iOS only, open the app and click
   **+** next to "macOS App" in the left column.)
4. **Business → Agreements:** the Free Apps agreement is enough for now. Before charging: the Paid Apps agreement,
   banking and tax forms.
5. **EU Digital Services Act:** App Store Connect asks whether you're a trader. A free app with no plans to earn can be
   "not a trader"; once you charge you're a trader and Apple shows your address, phone and email in the EU.
6. **Upload the builds:**
   ```bash
   UPLOAD=1 iOS/scripts/archive-appstore.sh
   PLATFORM=mac UPLOAD=1 iOS/scripts/archive-appstore.sh
   ```
   (or without `UPLOAD=1` to get `build/ios/export/Tuner.ipa` and upload it with Apple's Transporter app). The first
   run creates the distribution certificate and profile automatically. For the command line without Xcode's account,
   create an API key in App Store Connect → Users and Access → Integrations and pass `ASC_KEY_ID`, `ASC_ISSUER_ID`,
   `ASC_KEY_PATH`.
7. **TestFlight:** after processing (10–30 min) add yourself as an internal tester and install TestFlight builds on
   your iPhone and Mac (TestFlight is also a Mac app). This replaces the 7-day re-installs: remove the agent with `iOS/scripts/install-resign-agent.sh
   --remove`. (The App Store/TestFlight app has a different bundle ID from your current personal install, so it's a
   separate app with an empty library; turn on iCloud sync on both first to carry favourites and progress over.)
8. **App Information / Pricing:** category Entertainment (secondary: Photo & Video), price Free, availability all
   countries (you can exclude some).
9. **App Privacy:** "Data Not Collected". Privacy policy URL:
   `https://github.com/AhmedEzzat12/iptv-player-macos/blob/main/docs/app-store/privacy.md`.
10. **Age rating:** answer the questionnaire for what the *app* contains (nothing): no unrestricted web access, no
    user-generated content. If App Review asks for a higher rating because playlists can contain anything, accept it.
11. **Screenshots:** iOS: 6.9" iPhone (1320 × 2868) and 13" iPad (2064 × 2752). macOS: 16:10, e.g. 2880 × 1800.
    From the test kit only (invented channels and posters, never a real provider's content or real movie posters).
12. **Submit for review**, iOS and macOS versions together, with the notes below. Typical review: 1–3 days.

## Listing text

**Name:** Antenna: IPTV Player (30 characters max; checked free on 2026-11-08. Don't use "Xtream" or "Stalker" in
the name or keywords.)

**Subtitle:** Live TV, movies and shows

**Promotional text:** Your IPTV playlists, Apple TV–style: guide, catch-up, Continue Watching and downloads.

**Description:**

> Antenna is a beautiful, native player for the IPTV service you already have. Add your M3U playlist, Xtream Codes or
> Stalker portal login, and Antenna turns it into an Apple TV–style home for live TV, movies and shows.
>
> • Live TV with a program guide, now/next and catch-up
> • Movies and shows with artwork, seasons, episodes and Continue Watching
> • Up Next, Skip Intro and Skip Credits
> • Downloads for offline viewing
> • Picture in Picture and AirPlay
> • Plays almost any format (MKV, HEVC, AC-3 and more)
> • Optional iCloud sync with your Mac
> • Private: no accounts, no tracking, no ads
>
> Antenna does not provide any content. You need a subscription or playlist from an IPTV provider, and you are
> responsible for having the rights to what you play.

(For the Mac listing, leave out Picture in Picture if you like; everything else applies.)

**Keywords:** iptv,m3u,player,live tv,epg,guide,catchup,streaming,playlist,tv

**Support URL:** `https://github.com/AhmedEzzat12/iptv-player-macos/issues`

## App Review notes (paste into "Notes")

> Antenna is a media player for IPTV services the user already subscribes to. It contains no channels, playlists or
> content of its own and doesn't link to any.
>
> To test, tap "M3U Playlist" on the first screen and add this playlist of legally distributable streams (Apple's HLS
> examples and Blender Foundation films, CC BY):
> https://raw.githubusercontent.com/AhmedEzzat12/iptv-player-macos/main/docs/app-store/review-playlist.m3u
>
> NSAllowsArbitraryLoads: users connect to their own third-party IPTV servers, which we don't control and which
> commonly use plain HTTP and raw IP addresses for playlists, guides and streams.
>
> Background audio is used so audio keeps playing with the screen locked and for Picture in Picture.
>
> Downloads save titles from the user's own provider for offline viewing inside the app only, as the provider allows.

## Risks to know about

- **Guideline 5.2.3 (downloading media):** most IPTV players are approved, but a reviewer can object to Downloads.
  If that happens, reply that it's the user's own subscription; as a last resort ship a version with Downloads off.
- **Metadata services:** TMDB is free for non-commercial use with attribution; **before charging**, apply for TMDB's
  commercial terms (or keep TMDB as the user's own key, which is how it works now). Cinemeta (the default) has no
  published terms for third-party apps.
- **Rights-holder takedowns** of IPTV apps happen by court order in some countries (Spain, India); keep the listing
  neutral about providers.

## Before charging later

Paid Apps agreement, tax and banking; trader status for the EU; TMDB commercial terms; decide between a price and a
subscription (StoreKit). The licence already reserves selling Tuner to you.
