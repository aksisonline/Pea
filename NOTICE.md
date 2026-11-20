# Notices

## Responsible use

Pea is a general-purpose tool that saves media you already have the right to access. **We do not condone piracy.**
Only download content that you own, that is in the public domain or under a licence that permits it (for example
Creative Commons), or that the rights holder has given you permission to keep. You are responsible for following
the law where you live and the terms of the sites you use. Pea does not bypass DRM or paywalls, and the authors
accept no liability for how it is used.

Pea is free and non-commercial. It exists to make a creator's day-to-day work easier (saving your own uploads,
references, b-roll and music you are licensed to use). Donations are welcome but never required.

## Credits

Pea is built on the work of others. The downloads include **unmodified** copies of yt-dlp and FFmpeg so that nothing
else has to be installed. Pea runs them as separate programs; it does not link against them. Exact versions and
where they came from are listed in `VERSIONS.txt` next to the binaries (inside the app: `Pea.app/Contents/Resources/bin`,
on Linux `/opt/pea/tools`, on Windows the `tools` folder). yt-dlp is also kept up to date automatically in your user folder.

| Project | Used for | Licence |
| --- | --- | --- |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Finding and fetching media from video and audio sites | Unlicense |
| [FFmpeg](https://ffmpeg.org) | Merging streams, converting audio, embedding cover art | GPL-3.0+ (static builds, see below) |
| [Swift](https://www.swift.org) and SwiftPM | The language and toolchain | Apache-2.0 |
| [GTK 4](https://www.gtk.org), [Cairo](https://www.cairographics.org), [Pango](https://pango.gnome.org) | The Linux and Windows interface | LGPL-2.1+ |
| [curl](https://curl.se) | HTTP transport on Windows (ships with Windows) | curl licence |

FFmpeg binaries are built by third parties, who publish the corresponding source and build scripts:
[Martin Riedl](https://ffmpeg.martin-riedl.de) (macOS), [John Van Sickle](https://johnvansickle.com/ffmpeg/) (Linux),
[gyan.dev](https://www.gyan.dev/ffmpeg/builds/) (Windows). You can replace the bundled `ffmpeg` with your own build.
FFmpeg is a trademark of Fabrice Bellard. yt-dlp is released into the public domain under the
[Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE).

Inspiration:

- [MSC72m/media_downloader](https://github.com/MSC72m/media_downloader): the original idea of a small yt-dlp front end. No code was copied.
- [Blip](https://blip.net): the calm, single-purpose look and feel.
- [aria2](https://aria2.github.io): the multi-connection segmented download approach (re-implemented from scratch in Swift).

README badges and banner by [shieldcn](https://github.com/jal-co/shieldcn) (MIT).

Screenshots use *Big Buck Bunny* © 2008 Blender Foundation, [peach.blender.org](https://peach.blender.org), licensed
[CC BY 3.0](https://creativecommons.org/licenses/by/3.0/).

All trademarks (YouTube, Spotify, TikTok, Instagram, X, Pinterest, SoundCloud and others) belong to their owners.
Pea is not affiliated with or endorsed by any of them.
