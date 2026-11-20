<div align="center">

<img src="https://shieldcn.dev/header/glow.svg?title=Pea&subtitle=Copy+a+link.+Click+the+circle.+Drag+the+file+out.&logo=https://raw.githubusercontent.com/aksisonline/Pea/main/assets/icon.png&theme=green&size=banner" alt="Pea" width="100%" />

<a href="https://github.com/aksisonline/Pea/releases/latest/download/Pea-macOS.dmg"><img src="https://shieldcn.dev/badge/Download-macOS-22c55e.svg?logo=apple&size=lg" alt="Download for macOS" /></a>
<img src="https://shieldcn.dev/badge/Windows-coming_soon-71717a.svg?logo=windows&size=lg&variant=outline" alt="Windows: coming soon" />
<a href="https://github.com/aksisonline/Pea/releases/latest/download/Pea-linux-amd64.deb"><img src="https://shieldcn.dev/badge/Download-Linux-22c55e.svg?logo=linux&size=lg" alt="Download for Linux" /></a>

<img src="https://shieldcn.dev/github/release/aksisonline/Pea.svg?variant=secondary" alt="Latest release" />
<img src="https://shieldcn.dev/github/license/aksisonline/Pea.svg?variant=secondary" alt="MIT licence" />
<a href="https://buymeacoffee.com/aksisonline"><img src="https://shieldcn.dev/badge/Buy_me_a_coffee-support-FFDD00.svg?variant=secondary&logo=buymeacoffee" alt="Buy me a coffee" /></a>

</div>

<br />

<div align="center">
<img src="docs/screenshots/link.png" width="190" alt="A copied link lights the circle" />
<img src="docs/screenshots/type.png" width="190" alt="Video or audio" />
<img src="docs/screenshots/quality.png" width="190" alt="Original, high quality or save space" />
<img src="docs/screenshots/done.png" width="190" alt="Done: drag the file out" />
</div>

<br />

**Pea** is a tiny all-in-one downloader. Copy a link and the circle lights up; click it, pick *Video* or *Audio* and a quality, and the file lands in Downloads. Drag it straight out of the window to move it where you need it.

- **Video, audio, images and GIFs** from YouTube, Spotify tracks, SoundCloud, TikTok, Instagram, X, Pinterest and [the many other sites yt-dlp supports](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md)
- **Any direct file link** (HTTP/HTTPS) downloads over several connections at once
- **Cover art and metadata** are embedded in the file. Audio as Opus, MP3 or WAV; video is always MP4
- **Menu bar or window**, your choice. No accounts, no tracking, no ads

## Install

| | |
| --- | --- |
| **macOS 14+** | Open the `.dmg` and drag Pea to Applications. It isn't notarised, so the first time, right-click → **Open**. |
| **Windows** | Coming soon. |
| **Linux** | `sudo apt install ./Pea-linux-amd64.deb` |

**Nothing else to install.** [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [ffmpeg](https://ffmpeg.org) are inside, and yt-dlp quietly keeps itself current. Prefer to build it yourself? `./bundle.sh` on macOS, or `swift build -c release` anywhere.

## Please use it responsibly

Pea does not condone piracy. It is a free tool, made to save creators time, for content you own, that is openly licensed, or that you have permission to keep. You're responsible for how you use it. Pea is not affiliated with any of the sites it can read from. See [NOTICE.md](NOTICE.md).

## Credits

Built on [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [FFmpeg](https://ffmpeg.org), inspired by [media_downloader](https://github.com/MSC72m/media_downloader) and [Blip](https://blip.net). Badges by [shieldcn](https://github.com/jal-co/shieldcn). Full list and licences in [NOTICE.md](NOTICE.md).

<div align="center">

Free and always will be. If Pea saves you time, you can <a href="https://buymeacoffee.com/aksisonline">buy me a coffee ☕</a>.

MIT © [aksisonline](https://github.com/aksisonline)

</div>
