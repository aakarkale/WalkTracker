# First run, start to finish

For a Mac with Xcode installed and nothing else. No iOS experience assumed.

There are three separate things to get working, in this order: the app builds,
the app runs, the app has street data. Doing them out of order is the usual
way this goes wrong, because an app with no street data looks broken when it
is merely empty.

---

## 1. Setup

Open Terminal (Command-Space, type Terminal). Then:

```sh
git clone https://github.com/aakarkale/WalkTracker.git
cd WalkTracker
./Tools/setup-mac.sh
```

That checks Xcode, installs Homebrew and XcodeGen if they are missing, and
generates the Xcode project. It tells you what it is doing and stops with a
plain explanation if something is not right.

If it asks you to open Xcode once first, do that: Xcode needs you to accept
its licence and let it finish installing components before anything can build.
It is a one-time thing.

## 2. Give the app your own identifier

Every iOS app needs an identifier that is yours. The one in the repository is
a placeholder on a reserved example domain and Apple will refuse to sign it.

Open `project.yml` in any text editor and change **both** of these:

```
PRODUCT_BUNDLE_IDENTIFIER: com.example.walktracker
PRODUCT_BUNDLE_IDENTIFIER: com.example.walktracker.tests
```

to something of your own, keeping the `.tests` suffix on the second:

```
PRODUCT_BUNDLE_IDENTIFIER: com.aakar.walktracker
PRODUCT_BUNDLE_IDENTIFIER: com.aakar.walktracker.tests
```

It does not have to be a domain you own. It just has to be unique and not
`com.example`.

Then regenerate and open the project:

```sh
xcodegen generate
open WalkTracker.xcodeproj
```

Re-run `xcodegen generate` whenever you change `project.yml`. The
`.xcodeproj` is generated from it and is not itself worth editing.

## 3. Sign in

In Xcode:

1. **Xcode menu, Settings, Accounts**. Press **+**, choose Apple ID, sign in.
   A free Apple ID works.
2. Close Settings. In the file list on the left, click the blue
   **WalkTracker** project at the top.
3. Select the **WalkTracker** target, then the **Signing and Capabilities**
   tab.
4. Under **Team**, pick your name, which will say Personal Team.

If Xcode shows a red error about the bundle identifier being unavailable,
change it again in `project.yml` to something more unusual and re-run
`xcodegen generate`. Identifiers are globally unique across everyone.

## 4. Run it on the simulator first

Do this before touching your phone. It proves the app builds and runs, and
separates build problems from device problems.

At the top of the Xcode window there is a dropdown showing a device name.
Pick any iPhone simulator. Press the **play button**, or Command-R.

The first build takes a few minutes. Later ones are much faster.

The app will open on onboarding, then show an empty map and a city list where
every city says "Load a pack". That is correct: there is no street data yet.

## 5. Build street data

Back in Terminal:

```sh
cd Tools/citypack
./fetch_and_build.sh manhattan
```

This downloads Manhattan's streets from OpenStreetMap and builds a pack. It
takes a few minutes, most of it waiting on the download. When it finishes it
prints where the file is, something like `new-york.v1.sqlite.gz`.

Start with Manhattan rather than all five boroughs. The public servers often
refuse a query the size of the whole city, and Manhattan is plenty to see the
app working. `./fetch_and_build.sh --list` shows the other options.

If the download fails, it will say why. The usual causes are rate limiting,
in which case wait a few minutes, and an area that is too large.

## 6. Get the pack into the app

**On the simulator:** drag `new-york.v1.sqlite.gz` from Finder onto the
simulator window. It lands in the simulator's Files app. Then in WalkTracker:
**Cities**, tap **New York**, and pick the file.

**On a real iPhone:** AirDrop the file to yourself, or put it in iCloud Drive,
then the same three taps.

The city list will move New York into "Ready to walk" and the map will fill
with grey streets. Those are the streets you have not walked yet. They turn
green as you do.

## 7. Put it on your iPhone

The simulator cannot walk anywhere, so this is the part that actually works.

1. Plug the iPhone into the Mac with a cable.
2. On the phone, tap **Trust** and enter your passcode.
3. In Xcode, pick your iPhone from the device dropdown at the top.
4. Press play.
5. The first install will fail with an "Untrusted Developer" message. This is
   normal. On the phone go to **Settings, General, VPN and Device
   Management**, tap your Apple ID, and tap **Trust**.
6. Press play in Xcode again.

Then grant location access when it asks. For coverage to record while your
phone is in your pocket you need **Always**, which iOS will only offer after
you have used the app once with **While Using**.

## What to expect

Walk a few blocks and they turn green. The map will not update the instant
you step onto a street: matching smooths about eight seconds of movement
before deciding, which is what keeps it from painting streets you merely
walked past.

Coverage is deliberately cautious. If it is unsure where you were, it credits
nothing rather than guessing, so it under-reports rather than over-reports.

## Things that trip people up

**The app stops working after a week.** With a free Apple ID, apps expire
after seven days. Plug in and press play again to reinstall. A paid Apple
Developer Program membership extends this to a year. Check Apple's developer
site for the current price before signing up.

**"Could not launch" right after installing.** You have not trusted the
developer certificate yet. Step 7.5 above.

**Nothing records while the screen is off.** Location access is set to While
Using rather than Always. Change it in **Settings, WalkTracker, Location**.

**The percentage barely moves.** Manhattan has thousands of blocks. One walk
is a fraction of a percent. The block count underneath the percentage is the
number that visibly moves.

**Automatic recording does nothing.** It is off until you switch it on in
Settings, and it needs Always location access. It is off by default on
purpose: an app should not start recording where you go without being asked.

## If you get stuck

Run the checks that do not need Xcode:

```sh
./Tools/validation/run_all.sh
```

If those pass, the problem is in the Xcode setup rather than the code. The
most common causes, in order: the bundle identifier is still `com.example`,
no Team is selected, or `xcodegen generate` was not re-run after editing
`project.yml`.
