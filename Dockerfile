# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/powershell:latest

LABEL org.opencontainers.image.title="salmon-run" \
      org.opencontainers.image.description="File-based Kanban control plane with pond dispatch and model routing"

WORKDIR /salmon-run

# Copy the package into the image. The source repo contains no credentials,
# queue state, or private hostnames; runtime state lives in ~/.salmon.
COPY . /salmon-run/

# Install modules to a persistent location and validate the PondEngine loads.
# The image entry point is the public Start-SalmonRun.ps1 script.
RUN pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File /salmon-run/install.ps1

ENV SALMON_RUN_HOME=/salmon-home
VOLUME ["/salmon-home"]

ENTRYPOINT ["pwsh", "-NoProfile", "-NonInteractive", "-Command", "/salmon-run/Start-SalmonRun.ps1"]
CMD ["-DryRun"]
