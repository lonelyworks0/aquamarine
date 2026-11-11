# DisplayLink idle-damage diagnostic

Review artifact only. Nothing here changes the running session unless you run the script with `--go`.

The shell script does not change monitor mode, scale, `evdi` loglevel, or Hyprland config, and it does not clear the kernel log.

`aquamarine-0.15.1-damage-trace.patch` applies to aquamarine `f31c47a` (v0.15.1), the release this Hyprland binary was built against. It is not applied in this tree. Do not build or install it unless `trace-test --check` reports that uprobes cannot see `drmModeCreatePropertyBlob` or `CDRMAtomicImpl::commit`. With `AQ_DAMAGE_TRACE` unset it does not change commit behavior. Turning it on requires restarting Hyprland, which is why it is not the first step.

Run `diagnostics/aq-displaylink-diag.sh` with no `--go` first. The script prints the recovery command before it stops anything.
