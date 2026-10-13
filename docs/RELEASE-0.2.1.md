OpenDDPM 0.2.1 avoids redundant monitor writes when applying presets.

The transition planner reads the current monitor state and skips settings that
already match. Changing only the layout sends one layout write; changing only
a source sends only the necessary source write. Dell's automatic main/secondary
swap is accounted for, so a source swap can use a single command. Applying an
already-active preset continues to send no writes.

Keep this Mac visible remains enforced. Staging commands are retained when
needed to preserve the local input during a transition.

Validation: 4,204 core assertions covering starting layouts, source combinations,
write counts, and local visibility; native DDC packet validation; universal
Apple Silicon/Intel build. Intel hardware validation remains pending.

No external monitor-control app is required. macOS 13+; U4025QW is the validated
monitor model. The release is ad-hoc signed and is not Apple notarized.
