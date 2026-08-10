# Real KOReader, on a virtual screen, viewable in a browser.
#
# This is the one layer the Lua harness cannot test. That harness stubs KOReader, and
# the stubs are written from the same assumptions the plugin makes, so if a method name
# on the reader view or the annotation list is wrong, the harness agrees with the mistake
# and only the real thing disagrees. Hence: the actual desktop build, the actual plugin
# loaded by the actual plugin loader, drawn to an X display piped through noVNC.
FROM debian:bookworm-slim

ARG KOREADER_VERSION=v2026.07.1

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      xvfb x11vnc novnc websockify \
      libsdl2-2.0-0 libglib2.0-0 libgomp1 \
      fonts-dejavu-core fontconfig \
      ca-certificates curl xz-utils procps sqlite3 xdotool \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/koreader.tar.xz \
      "https://github.com/koreader/koreader/releases/download/${KOREADER_VERSION}/koreader-linux-x86_64-${KOREADER_VERSION}.tar.xz" \
 && mkdir -p /opt/koreader \
 && tar -xJf /tmp/koreader.tar.xz -C /opt/koreader \
 && rm /tmp/koreader.tar.xz \
 && ls -la /opt/koreader

COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

EXPOSE 6080
ENTRYPOINT ["/usr/local/bin/start.sh"]
