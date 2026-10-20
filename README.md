# Backup HQ

A native Mac app that keeps an eye on the folders you care about and makes sure a copy of
everything exists wherever you said it should: on an external disk, in Amazon S3, or both.
It never deletes anything, it verifies every copy by SHA-256, and it tells you plainly
what exists in only one place.

It started life as a tool to rescue a large photo library out of Adobe Lightroom's cloud,
and it still does that well, but you can use it without Lightroom at all.

> **For Claude (or any assistant) setting this up for someone:** read this whole file, then
> follow *Quick start*. Everything the app needs from the person is listed under
> *What you will be asked for*. Do not run the real transfer of a large library until they
> have said to.

## What it does

- **Tracked folders.** Add any folder on the Mac or on an external disk. The app inventories
  it in place and never moves or renames anything inside it.
- **Targets per folder.** For each folder, tick where a copy should also live: a *backup disk*
  (a root folder on an external drive) and/or an *S3 archive* (a bucket and prefix). Nothing is
  copied anywhere you did not tick. An S3 storage class can be chosen per folder.
- **Verification.** Every file is fingerprinted (SHA-256) before it is copied and checked again
  after. Old copies are re-checked in the background on a schedule you set.
- **Nothing is ever lost.** Unticking a target never deletes copies. A file removed from a folder
  is marked as gone; its copies elsewhere stay. A changed file keeps its previous version
  beside the new one on the backup disk, and the S3 bucket keeps versions too.
- **Noticing changes.** Folders are looked at when the app opens, on a schedule (hourly by
  default), a couple of minutes after something changes in them (using macOS's own change
  journal, so repeat looks only visit the directories that changed), and when a disk is plugged
  in. Ignore rules keep build output, caches and temp files out.
- **Warnings.** The Home page says what is at risk: files below policy, disks not seen for a
  while, disks nearly full, copies that failed a check, jobs that failed. Optional macOS
  notifications.
- **Costs.** Each S3 place shows an estimated monthly storage bill, priced per storage class
  actually in use.
- **Lightroom (optional, off by default).** Switch on *Work with Adobe Lightroom* in Settings and
  the app reads Lightroom desktop's local catalogue (read-only) as the list of originals that
  should exist, and can take the originals Lightroom downloads and treat them like any other
  tracked folder.
- **Phone app (optional).** A small iOS app reads a status file the Mac publishes to S3 and
  shows progress and warnings. The phone never touches your files.

## Requirements

- macOS 15 or newer, Apple Silicon or Intel.
- Xcode 16 or newer (for the Swift 6 toolchain) and [xcodegen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`).
- For S3: an AWS account, one bucket, and an IAM user with the policy in `docs/iam-policy-backup.json`.
  Any S3-compatible service with SigV4 should also work, though only AWS has been tested.

## Quick start

```bash
git clone https://github.com/bartraigures/backup-hq.git BackupHQ
cd BackupHQ
cp -n project.local.example.yml project.local.yml   # signing overrides; the default signs to run locally
xcodegen generate
xcodebuild -project BackupHQ.xcodeproj -scheme BackupHQ -configuration Release build
# The app lands in Xcode's DerivedData; copy it somewhere handy:
APP=$(xcodebuild -project BackupHQ.xcodeproj -scheme BackupHQ -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/ {print $3}')
ditto "$APP/BackupHQ.app" "/Applications/Backup HQ.app"
open "/Applications/Backup HQ.app"
```

The default build is signed "to run locally", which is all a personal Mac needs. To sign with
your own Apple team instead, edit `project.local.yml` as the comments in it show, then run
`xcodegen generate` again. That file is git-ignored, so your team id never ends up in the repo.

Core logic is a Swift package you can test on its own:

```bash
cd Packages/BackupHQCore
swift test
swift build -c release --product backuphq-cli   # a command-line driver for the same engine
```

## First run

1. **Folders page → Add a folder.** Pick a folder to look after. It is scanned straight away.
2. **Add a backup disk.** Choose a root folder on an external drive. Each tracked folder you
   tick for it will be mirrored at `<root>/<folder name>/<path inside the folder>`.
3. **Add an S3 archive** (see below). Each ticked folder is stored at
   `<prefix>/<folder name>/<path inside the folder>`.
4. On each folder's card, tick where copies should also live, and pick a storage class for S3
   if the bucket's default is not what you want for that folder.
5. Press **Start**. The menu-bar shield shows what is happening; closing the window does not
   quit the app.

Settings has the schedule, the settle time after a change, the ignore list, verification
cadences and the warning thresholds. The defaults are sensible.

## Setting up S3

### 1. Create a bucket

In the AWS console (or with the CLI), create a bucket in the region closest to you. Turn on
**Block all public access**, **Bucket versioning** and default encryption. Add the lifecycle
rules in `docs/bucket-lifecycle.json`: one aborts unfinished multipart uploads after a week,
the other expires old versions after a year (adjust or drop that one if you want versions
kept forever).

```bash
aws s3api create-bucket --bucket YOUR-BUCKET-NAME --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1
aws s3api put-public-access-block --bucket YOUR-BUCKET-NAME \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket YOUR-BUCKET-NAME --versioning-configuration Status=Enabled
aws s3api put-bucket-lifecycle-configuration --bucket YOUR-BUCKET-NAME --lifecycle-configuration file://docs/bucket-lifecycle.json
```

The app can create the bucket itself (there is a tick box in the Add S3 sheet) but then the IAM
user needs `s3:CreateBucket` too, and you still have to set versioning and the lifecycle rules
by hand, so creating it first is simpler.

### 2. Create an IAM user for the Mac

Create an IAM user with **programmatic access only** (no console password) and attach
`docs/iam-policy-backup.json` with `YOUR-BUCKET-NAME` replaced. It can read and write objects
in that one bucket and nothing else. Make an access key for it.

### 3. Give the app the credentials

Either of these works; the app tries the Keychain first, then the profile.

- **In the app.** Folders page → *Add an S3 archive* → tick *Enter access keys instead of using
  a profile from ~/.aws* and paste the key id and secret. They are stored in your login Keychain
  under the service `BackupHQ.s3`, one item per S3 location, and never written to disk in plain
  text.
- **From `~/.aws/credentials`.** If you already use the AWS CLI, leave the tick box off and pick
  the profile name. The app reads `~/.aws/credentials` and `~/.aws/config` the same way the CLI
  does (key id, secret, optional session token, and the profile's region).

Set the region to the bucket's region. Pick a default storage class for the location; each
folder can override it. A rough guide:

| Class | Good for | Cost (eu-west-1, per GB-month) | Getting it back |
|---|---|---|---|
| Standard | Folders that still change | $0.023 | instant |
| Glacier Instant Retrieval | Rarely-read, may change | $0.004 (128 KB minimum per object) | instant |
| Glacier Deep Archive | Things that will never change | $0.00099 (+ 40 KB index per object, 180-day minimum) | 12 hours, paid |

Renamed or moved files are uploaded again under the new name (the old object is kept), so
keep folders you intend to reorganise out of Deep Archive.

### 4. (Optional) The phone app

The Mac publishes `<prefix>/_backuphq/status.json` to each S3 archive every 30 seconds
while running (switch it off in Settings → Phone). Create a second IAM user with
`docs/iam-policy-phone.json`, which can only read that one path, and enter its key in the
phone app's Settings. Build the iOS target from the same project in Xcode and run it on your
phone with your Apple ID.

## What you will be asked for

- Which folders to look after, and for each one, whether it should also be on the backup disk,
  in S3, or both.
- An external disk to use as the backup root (any format macOS can write).
- For S3: bucket name, region, an access key id and secret (or an existing `~/.aws` profile),
  and a default storage class.
- Whether the app should open at login and start work when it opens (Settings).

## Where things live on this Mac

- Catalogue: `~/Library/Application Support/Backup HQ/catalog.sqlite` (SQLite). It is the
  app's memory of every file, fingerprint and copy. Settings → Advanced can show it in Finder.
- Credentials entered in the app: login Keychain, service `BackupHQ.s3`.
- Engine log: `log show --info --last 1h --predicate 'subsystem == "com.backuphq.mac"'`
  (use your bundle id if you changed it). The Activity page in the app shows the same events.

## How it decides what to do

- A **look** at a folder compares each file's size and modification time with what it recorded
  last time. Unchanged files are left alone. New or changed ones are fingerprinted, then copied
  to each ticked target that lacks that fingerprint.
- Permission or tag changes do not trigger anything. A touched-but-identical file is re-read
  once and nothing is uploaded. A file whose bytes changed is copied again, and both the
  backup disk and S3 keep the previous version.
- Repeat looks use the volume's change journal (FSEvents), so they only visit the directories
  that changed. *Look through it again* on a folder's card walks the whole folder.
- A file that disappears before it could be copied is noted and skipped, not counted as a
  failure. A disk that is unplugged makes its jobs wait rather than fail.

## Ignore rules

Settings → *Ignored everywhere* holds the standard list: build output and package caches,
temp and partial files, system folders, Lightroom previews. A rule is a name (`node_modules`,
`*.tmp`), matched at any depth, or a path relative to the folder (`Exports/*`). `.git` is not
on the list on purpose, since a repository's history is often the only copy. Each folder can
add rules of its own or opt out of the standard list from its card's menu.

## Lightroom

Off by default; turn on *Work with Adobe Lightroom* in Settings. With Lightroom's desktop app
installed, the Lightroom page shows what the local catalogue
says exists in the cloud and whether each original is on a disk the app knows about. To get the
originals out of the cloud, turn on *Preferences → Local Storage → Store a copy of all originals
at the specified location* in Lightroom, point it at a folder on a disk with room, and add that
folder to Backup HQ like any other. Lightroom does the downloading; Backup HQ fingerprints,
matches each file to the catalogue, and copies it to the targets you tick.

## Design notes

- Core logic is `Packages/BackupHQCore`: a SQLite catalogue behind a single actor, the job
  engine (`scan → hash → import | backup | upload`, plus `verify` and `reclass`), an S3 client
  with SigV4 and resumable multipart uploads, the FSEvents watcher and the Lightroom catalogue
  reader. The Mac app in `BackupHQMac` and the phone app in `BackupHQiOS` are thin SwiftUI
  layers over it.
- Jobs are persisted, idempotent and resumable: pause, quit or reboot at any point and the
  queue carries on afterwards.
- The code identifiers (`BackupHQ`, `backuphq-cli`) are the project's original name;
  the product name is Backup HQ.

## Privacy and safety

The app talks to exactly two things outside this Mac: the S3 endpoint you configured, and
Apple's notification service for local notifications. There is no telemetry. It never deletes
a copy on its own; deletions happen only when you ask for them in the app.

## Licence

MIT, see `LICENSE`.
