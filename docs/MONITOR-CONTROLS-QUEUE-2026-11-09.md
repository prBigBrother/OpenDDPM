# Editable monitor controls and queued writes

The monitor settings sliders hide the implicit Form label column and use the
full row width. They are continuous sliders; their final values are rounded
to the monitor's integer percentage rather than rendered as 101 tick marks.

Picture settings and HDR share a serial request queue. A confirmed value and
the latest requested value are separate: controls display the requested value
immediately, while confirmed state changes only after successful readback.
Pending changes to the same setting coalesce to the latest value, preserving
the order of different controls. Automatic brightness's enabled/range fields
keep separate masks and merge without overwriting one another.

Monitor activity no longer disables picture controls or the whole settings
form. Edits made during a preset transition wait until it finishes. Preset
transitions wait for an active picture/HDR operation, and a newer preset can
still supersede an older pending selection. The quick-menu preset buttons
also remain selectable while another preset applies.

Existing brightness bursts retain prompt intermediate writes and verification
of the settled target. If a preset interrupts verification, the unconfirmed
target stays queued. Settings retain their last confirmed values after errors,
expose the error, and continue with subsequent queued commands. An error is
cleared by a successful retry for the same setting.

Queued changes remain bound to the selected serial. A changed display ID for
that serial preserves queued edits; selecting another monitor drops them.
Generation checks keep old completions from publishing into a new target.
Unavailable controls and the monitor's automatic-brightness lock still apply.
Display-mode confirmation retains its existing keep/revert workflow.

Regression coverage exercises cross-control ordering and coalescing, previews,
paused execution, packed fields, failed writes followed by successful edits,
HDR serialization, interrupted brightness readback, display reconnection,
monitor changes, and waiting/superseding preset transitions.

The full suite passed (4,207 core and 37 coordinator assertions, plus picture,
brightness, wake and native-DDC checks). The additional pre-reconnect HDR
completion regression also passed. The universal app was signed with the
existing identity and installed; full-width sliders were visually verified.
The live journal confirms picture writes and readback during user interaction.
Automated slider manipulation was interrupted by user navigation, so no
restoration was applied over the user's newer settings. The compact local
record is `validation/queued-controls-live-2026-11-09.json`.
