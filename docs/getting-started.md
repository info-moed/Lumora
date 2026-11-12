---
title: Getting started
nav_order: 2
---

# Getting started

This guide assumes **no prior experience** with Terminal, Xcode or HDR video. It takes you from a fresh Mac to your
first converted video. Plan on 30–60 minutes, mostly waiting for downloads.

If you already know your way around, the [Quick start in the README](https://github.com/info-moed/Lumora/blob/main/README.md#quick-start) is five commands.

---

## Contents

1. [Check your Mac](#step-1-check-your-mac)
2. [Install Xcode](#step-2-install-xcode)
3. [Open Terminal (and how to use it)](#step-3-open-terminal)
4. [Install Homebrew and the basic tools](#step-4-install-homebrew-and-the-basic-tools)
5. [(Optional) Install the extra encoders](#step-5-optional-install-the-extra-encoders)
6. [Download Lumora](#step-6-download-lumora)
7. [Build Lumora](#step-7-build-lumora)
8. [Open Lumora for the first time](#step-8-open-lumora-for-the-first-time)
9. [Your first conversion](#step-9-your-first-conversion)
10. [Updating Lumora later](#updating-lumora-later)
11. [Where to go next](#where-to-go-next)

---

## Step 1: Check your Mac

Lumora needs:

- **An Apple silicon Mac** (M1, M2, M3, M4, M5 or later), and
- **macOS 27 or later.**

To check, click the **Apple menu** (top-left corner of the screen) → **About This Mac**. Look at:

- **Chip:** it should say "Apple M…". If it says "Intel", Lumora won't run on this Mac.
- **macOS:** the version number should be 27 or higher. If not, update in **System Settings → General → Software Update**.

You also need about **20 GB of free disk space** for Xcode, plus room for the videos you make.

---

## Step 2: Install Xcode

Xcode is Apple's free developer tool. Lumora is distributed as source code, so Xcode turns that code into an app.

1. Open the **App Store** app.
2. Search for **Xcode** and click **Get** / **Install**. It's large (several GB), so this can take a while.
3. When it finishes, **open Xcode once**. It may ask to install additional components; click **Install** and enter
   your Mac password if asked.
4. If it asks which platforms you want, **macOS** is all Lumora needs. You can skip iOS, watchOS and the others.
5. You can quit Xcode afterwards. You don't need to keep it open.

> **Tip:** Xcode must be version 27 or later. Check in Xcode → About Xcode.

---

## Step 3: Open Terminal

Terminal is an app where you type commands instead of clicking. You'll only need it for a few copy-and-paste steps.

- Open it: press **⌘ Space**, type **Terminal**, press **Return**.
- A window appears with a line ending in `%`. That's the *prompt*: Terminal is waiting for a command.

**How to run a command from this guide:**

1. Copy the text from a gray box (e.g. `xcode-select -p`).
2. Click in the Terminal window, paste with **⌘V**, press **Return**.
3. Wait until the prompt (`%`) comes back before running the next one.

**Try it now.** This checks that Xcode's command-line tools are set up:

```bash
xcode-select -p
```

It should print a path such as `/Applications/Xcode.app/Contents/Developer`. If it prints an error instead, run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

`sudo` asks for your Mac password. Nothing appears while you type it; that's normal. Press **Return** when done.

> **Good to know:** If a command seems stuck, it may simply be busy. Downloads and builds print progress, then return
> to the prompt. To cancel a running command, press **Control-C**.

---

## Step 4: Install Homebrew and the basic tools

[Homebrew](https://brew.sh) is the standard way to install command-line tools on a Mac. Lumora uses it to get
[**XcodeGen**](https://formulae.brew.sh/formula/xcodegen) (which creates the Xcode project) and [**FFmpeg**](https://formulae.brew.sh/formula/ffmpeg) (which reads many video
formats and joins the finished file together).

1. Check whether you already have Homebrew:

   ```bash
   brew --version
   ```

   If it prints a version number, skip to step 3.

2. Install Homebrew. This is the official command from [brew.sh](https://brew.sh). Check there if you want to
   confirm it's current:

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

   Follow its prompts. **At the end it prints "Next steps"** with two or three commands to add Homebrew to your
   path. Copy and run them, then close and reopen Terminal.

3. Install the tools Lumora needs:

   ```bash
   brew install xcodegen ffmpeg git
   ```

That's everything required. Hardware **HEVC** and **ProRes** exports, the formats most people want, now work.

---

## Step 5: (Optional) Install the extra encoders

Skip this if you only want HEVC (H.265) or ProRes files. Install it if you want:

| You want | Install |
|---|---|
| **AV1** files (smaller, modern players) | [`svt-av1`](https://formulae.brew.sh/formula/svt-av1) (and [`aom`](https://formulae.brew.sh/formula/aom) for the 12-bit / 4:4:4 "AV1 Pro" option) |
| **12-bit HEVC** | [`x265`](https://formulae.brew.sh/formula/x265) |
| **H.266 / VVC** | [`vvenc`](https://formulae.brew.sh/formula/vvenc) |
| **Quality targets** (encode to "looks identical") | [`libvmaf`](https://formulae.brew.sh/formula/libvmaf) |
| **Dolby Vision / HDR10+** metadata | [`dovi_tool`](https://formulae.brew.sh/formula/dovi_tool), [`hdr10plus_tool`](https://formulae.brew.sh/formula/hdr10plus_tool), [`gpac`](https://formulae.brew.sh/formula/gpac) (MP4Box), [`mkvtoolnix`](https://formulae.brew.sh/formula/mkvtoolnix) |

Install all of them at once with the included script (run it from the Lumora folder after Step 6):

```bash
scripts/install-encoders.sh
```

Or pick individual ones, for example just AV1:

```bash
brew install svt-av1
```

> **Notes**
> - The script also tries to build **AV2 (AVM)** from source. That's slow and only needed for the experimental AV2
>   export. If it fails, everything else still works.
> - Homebrew formula names change occasionally. If one isn't found, try `brew search <name>`.
> - You can install encoders any time later; Lumora detects them when it starts.

---

## Step 6: Download Lumora

**Option A: with git (recommended, makes updating easy).** This downloads Lumora into a folder called `Lumora` in
your home folder:

```bash
cd ~ && git clone https://github.com/info-moed/Lumora.git
```

**Option B: as a ZIP.** On the [GitHub page](https://github.com/info-moed/Lumora), click the green **Code** button →
**Download ZIP**, then double-click the ZIP to unpack it. Move the folder somewhere sensible, such as your home
folder, and rename it `Lumora` if it's called `Lumora-main`.

Now move Terminal into that folder (adjust the path if you put it elsewhere):

```bash
cd ~/Lumora
```

---

## Step 7: Build Lumora

"Building" turns the source code into an app. Pick **one** of these two ways.

### Way 1: one command in Terminal

From inside the Lumora folder:

```bash
xcodegen
```

This creates `Lumora.xcodeproj`. Then build the app:

```bash
xcodebuild -project Lumora.xcodeproj -scheme Lumora -configuration Release -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- build
```

It prints a lot of text. The first build takes a few minutes. At the end you should see **`** BUILD SUCCEEDED **`**.

Your app is now at `build/DerivedData/Build/Products/Release/Lumora.app`. Copy it to your Applications folder:

```bash
cp -R build/DerivedData/Build/Products/Release/Lumora.app /Applications/
```

### Way 2: in Xcode

```bash
xcodegen && open Lumora.xcodeproj
```

Xcode opens the project. Press **⌘R** (or click the ▶ button at the top-left). Xcode builds Lumora and launches it.

> **"Signing" errors in Xcode?** Click the **Lumora** project in the left sidebar → **Lumora** target →
> **Signing & Capabilities**, and choose **Sign to Run Locally** (or your own Apple ID team). See
> [Troubleshooting](troubleshooting.md#build-problems).

---

## Step 8: Open Lumora for the first time

Open **Lumora** from your Applications folder (or from Xcode).

- **Simple mode** opens first. That's the friendly view; you can switch to **Pro** with the selector at the top
  of the window.
- A banner may suggest **Optimize for this Mac**. It's optional. It spends a while measuring your Mac to pick the
  fastest settings. You can dismiss it and run it later from **Tools → Optimize for this Mac…**.
- Lumora's interface is always dark, to keep the picture judgment honest.

> **macOS says the app "can't be opened"?** Apps you build yourself normally open fine. If you downloaded a built
> `Lumora.app` from someone else, right-click it → **Open** → **Open**. See
> [Troubleshooting](troubleshooting.md#the-app-wont-open).

---

## Step 9: Your first conversion

Let's turn a video into an HDR10 file for your TV. Any video works: a phone clip, a movie file you own, a screen
recording.

1. **Drop the file** onto the Lumora window (or click **Choose a file…**).
2. Lumora reads the whole file once: scenes, brightness, motion, grain. You'll see progress at the bottom and an
   info panel on the picture. A typical film takes a few minutes; a short clip, seconds.
3. Under **What do you want to do?**, pick a goal:
   - **Watch it on my TV**: best picture for a modern TV.
   - **Archive it**: keep the best quality, smaller file.
   - **Make it much smaller**: biggest size savings.
   - **Share it or play it anywhere**: maximum compatibility.
   - **Make motion smoother**: raise the frame rate.
4. If your TV or player can't play **AV1**, untick **My TV or player can play AV1**.
5. Read **Lumora recommends**. Each setting has a one-line reason. The **Result** section estimates the file size
   and time before you start.
6. Click **Export…**, check the settings, click **Export…** again and choose a folder. Lumora names the file after
   the source, the look and the format, e.g. `Holiday – Natural – HDR10.mov`.
7. Watch progress at the bottom of the window. **Pause** in the toolbar pauses without losing work.

**What you'll get:** with the default "Watch it on my TV" goal and an SDR source, an HDR10 file with brighter
highlights that plays on HDR TVs, Apple TV, Plex and Infuse. Play it on an HDR screen to see the difference. On a
non-HDR screen, HDR files look dim or washed out. That's the screen, not the file.

> **Not sure what HDR10, PQ or "nits" mean?** Read [HDR and video basics](hdr-basics.md). It takes 10 minutes and
> makes every setting in Lumora make sense.

---

## Updating Lumora later

If you used git (Option A), from the Lumora folder:

```bash
git pull
```

Then rebuild (Step 7). If you downloaded a ZIP, download a fresh ZIP and build again.

---

## Where to go next

- [User guide](user-guide.md): everything in Simple and Pro mode, the Tools menu and every window.
- [HDR and video basics](hdr-basics.md): the concepts behind the settings.
- [Troubleshooting](troubleshooting.md): if something goes wrong.
- [Command-line guide](command-line.md): when you're ready for Terminal power-user features.
