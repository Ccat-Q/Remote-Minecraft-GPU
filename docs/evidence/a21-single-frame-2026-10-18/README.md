# Accepted single remote frame (not multi-frame acceptance)

The screenshot is the original user attachment, not a reconstructed fixture.
`provenance.json` preserves the full device report Build Provenance and extracts
the observed counters/completions. `ubuntu.log` is the actual service journal
for the matching session; counters after the screenshot can exceed the phone's
snapshot because GL finish/hold traffic continues without another PRESENT.

App: [39101559555](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/39101559555),
native gate: [39101561824](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/39101561824).
Proxy-only diagnostics: [39123127770](https://github.com/Ccat-Q/Remote-Minecraft-GPU/actions/runs/39123127770).
Original user image attachment ID: `2A521BFF-ED6B-4831-9945-45CB7E003859`.

See [multi-frame procedure](../../a21-remote-present.md#a21-final-multi-frame-batch)
for the next, separately unaccepted device gate. No CI-generated screenshot or
performance estimate is substituted for phone evidence.
