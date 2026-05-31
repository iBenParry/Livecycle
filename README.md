# Livecycle
### Automated Wallpaper Manager

Livecycle automatically changes your desktop wallpaper based on the **time of day** or **current weather** at your location. Import your own wallpaper files, assign them to time slots or weather conditions, and let Livecycle handle the rest.

> **Requires** [Lively Wallpaper](https://rocksdanister.github.io/lively/) to render wallpapers on your desktop.

---

## Features

- **Import wallpapers directly** — drag in MP4, GIF, JPG, PNG or WEBM files
- **Time of Day scheduling** — assign wallpapers to custom time slots (e.g. Morning, Evening, Night)
- **Weather-based switching** — automatically switch based on live weather at your location (Clear, Cloudy, Rainy, Snowy, Stormy, Foggy)
- **Built-in library** — preview, rename and manage all your wallpapers in one place
- **Set & Preview** — set a wallpaper permanently or preview it for 5 seconds before it reverts
- **Automated scheduler** — uses Windows Task Scheduler to silently switch wallpapers at the right time
- **Lively detection** — automatically detects your Lively installation or guides you to download it

---

## Getting Started

### 1. Install Lively Wallpaper
Download and install [Lively Wallpaper](https://rocksdanister.github.io/lively/) — this is required for Livecycle to display wallpapers on your desktop.

### 2. Install Livecycle
Download the latest installer from the [Releases](../../releases) page and run it.

### 3. Import your wallpapers
On first launch, click **Browse for files** to import your wallpaper files. Supported formats: MP4, GIF, JPG, PNG, WEBM.

### 4. Assign wallpapers
Go to **Time of Day** or **Weather** and assign wallpapers to each slot using the **Browse** button.

### 5. Set up automation
On the **Home** page, click **Set up automation** to register the Windows Task Scheduler task. This only needs to be done once and will prompt for administrator approval.

### 6. Save
Hit **Save Changes** — your wallpapers will now change automatically.

---

## Screenshots

*Coming soon*

---

## Requirements

- Windows 10 or later
- [Lively Wallpaper](https://rocksdanister.github.io/lively/) (free)

---

## How it works

Livecycle manages its own wallpaper library stored in `%AppData%\Livecycle\wallpapers`. When a scheduled time or weather condition is met, it calls Lively's command line interface to set the correct wallpaper silently in the background.

---

## Built with

- PowerShell + WPF (GUI)
- [Open-Meteo](https://open-meteo.com/) — free weather API (no key required)
- [Nominatim](https://nominatim.org/) — free geocoding API
- [PS2EXE](https://github.com/MScholtes/PS2EXE) — PowerShell to EXE compiler
- [NSIS](https://nsis.sourceforge.io/) — installer

---

## License

MIT — free to use, modify and distribute.

---

*Created by Ben Parry*
