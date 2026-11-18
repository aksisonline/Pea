# Dev/test image for the Linux port: Swift + GTK4 + Xvfb + screenshot tools + yt-dlp/ffmpeg.
FROM swift:6.1
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgtk-4-dev pkg-config libglib2.0-dev libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev \
      xvfb xauth xdotool imagemagick x11-utils xclip xsel wl-clipboard \
      dbus dbus-x11 libglib2.0-bin \
      fonts-inter fonts-dejavu-core fonts-noto-color-emoji adwaita-icon-theme librsvg2-common \
      ffmpeg python3 python3-pip pipx ca-certificates curl python3-gi gir1.2-gtk-4.0 python3-dbus python3-gi-cairo \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages --no-cache-dir -U "yt-dlp[default]"
ENV GDK_BACKEND=x11 NO_AT_BRIDGE=1 LIBGL_ALWAYS_SOFTWARE=1 GSK_RENDERER=cairo
WORKDIR /src
