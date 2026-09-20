# Shipping notes

What this app has to get past before anyone can use it. Not legal advice; have
a lawyer read anything you publish.

## The main review risk

Continuous background location is the most scrutinised permission on iOS, and
this app wants the strongest form of it. That is the single largest obstacle
between this repository and the App Store, and it is worth planning for rather
than discovering at submission.

Apple's guidelines require that background location be needed for features
users can see, and that the app not request more access than those features
need. This app has a genuine case: it records which streets you walked, and a
walk continues with the phone in a pocket and the screen off. That is the
textbook justification. What gets apps rejected is usually presentation rather
than substance.

What to do about it:

- **Ask in stages.** The code requests When In Use first and only offers to
  upgrade to Always after the user has recorded something and can see what the
  app does with it. Requesting Always on first launch, before any value is
  shown, reads as overreach and is denied by users as often as by reviewers.
- **Make the app work without Always.** It does. With When In Use you get
  tracking while the app is open. Degrade, do not block.
- **Leave the background indicator on.** The code does. Hiding it on a location
  recorder invites exactly the scrutiny you are trying to avoid.
- **Write the purpose strings specifically.** The generic ones fail. Say what
  is recorded, when, and what the user gets.
- **In review notes, say plainly** that no location data leaves the device,
  that there is no account, and that nothing is uploaded, because that is true
  here and it is the reviewer's main question.

## App privacy disclosure

The App Store privacy questionnaire asks what you collect. As the code stands:

| Question | Answer |
|---|---|
| Data collected | None, in Apple's sense of the word |
| Location used | Yes, precise, on device only |
| Linked to identity | No, there is no identity |
| Used for tracking | No |
| Third-party SDKs | None |

"Collect" in Apple's terms means transmitted off device. This app does not
transmit location anywhere. The only outbound request is fetching a city pack
over HTTPS, which reveals the selected city to whoever hosts the packs and
nothing else. If you add analytics, crash reporting or sync later, every row
above changes and the disclosure has to change with it.

## What to tell users

The facts a privacy policy needs, in plain terms:

- The app records your location while a walk is running, including when the
  screen is off, and stores it on your device.
- If automatic recording is switched on, it can start a walk by itself when it
  detects you walking. It is off until you turn it on.
- It keeps every recorded position permanently, so coverage can be rebuilt when
  street data or the matching algorithm changes.
- The app never sends any of it anywhere. There is no account and no sync. If
  you export a backup or a GPX file, you choose where that file goes, and
  iCloud Drive is a normal choice.
- Deleting your data in Settings erases the traces and reclaims the disk pages
  holding them. It cannot reach a backup you have already exported.
- Deleting the app deletes everything it holds. A backup is how you avoid
  losing a year of walking.
- The app asks for motion data to tell walking from riding, so a bus ride down
  a street is not counted as having walked it.
- City street data is downloaded from a server, which learns which city you
  chose and nothing else.

Be specific about the permanence. "We store your location history forever" is
a strong claim to make to a user, and the honest reason is worth giving: it is
what lets the app fix its own past mistakes rather than lock them in.

## Street data licensing

Packs are derived from OpenStreetMap, which is published under the Open
Database License. Two obligations follow that are easy to miss:

1. **Attribution.** "© OpenStreetMap contributors" must be visible to users.
   The Settings screen carries it. Do not remove it.
2. **Share-alike on derived databases.** The ODbL has conditions about
   distributing a derived database. A city pack is plainly a derived database.
   This does not prevent a commercial or paid app, but it does mean the pack
   files themselves carry obligations. Get this reviewed before you charge for
   anything.

## Before you can ship

- [ ] Replace the placeholder bundle identifier and set a signing team.
- [ ] Build at least one real city pack with `Tools/citypack` and host it over
      HTTPS. Until then the city list is empty by design.
- [ ] Put the real pack base URL in `cities.json`, replacing the placeholder,
      which points at an invalid domain on purpose so a misconfigured build
      fails loudly instead of fetching something unexpected.
- [ ] Paste each built pack's digest and size into `cities.json`.
- [ ] Measure battery drain on a real device over a real walk. It is unmeasured
      and continuous GPS is expensive.
- [ ] Walk a real city and check the coverage it produces against what you
      actually walked. Every accuracy figure in this repository comes from
      simulation.
- [ ] Decide what happens when a user walks somewhere with no pack coverage,
      such as a park path OpenStreetMap does not have. Today they get no credit
      and no explanation.
