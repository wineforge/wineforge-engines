# Engine capabilities

Wineforge engine capabilities are a versioned contract between an engine build
and the runtime selecting it. They describe optional behavior; they do not
enable an application policy by themselves.

The source manifest records declarations as either `planned` or `provided`.
Only `provided` declarations for the current build target are copied into an
artifact. A provided capability must name every source patch that implements
it. The generator refuses to advertise the capability unless each named patch
is present in the source manifest and applies to the current target. Patch
digests are independently checked before the build.

This distinction prevents a roadmap entry from being mistaken for executable
support. Consumers must use the `provided` array from runtime metadata and must
not infer support from a source manifest's planned declarations.

## Version 1 identifiers

- `input.keyboard.preset.mac-native` covers the Mac driver's side-specific
  Command-to-Control and Option-to-Alt policy.
- `input.keyboard.mapping` covers arbitrary chord-to-key output.
- `input.scroll.keyboard-to-scroll` covers bounded process-local rules that
  translate key-down events to horizontal or vertical wheel input.
- `input.scroll.precise`, `input.scroll.horizontal`, and
  `input.scroll.momentum` describe physical pointing-device scroll behavior.
- `input.scroll.page`, `input.scroll.edge`, and `input.scroll.drag` are separate
  contracts because they need viewport or pointer-button lifecycle semantics.
- `macos.window-isolation.strict` covers process-local handling of Wine-owned
  transient windows across application activation and macOS Spaces. Version 1
  explicitly requires no observation of other processes' windows and no
  Accessibility, Screen Recording, or Input Monitoring permission.
- `host.bridge` describes the engine transport primitives that a Wineforge
  runtime may compose with a separately authorized native service. Advertising
  the primitive does not authorize a native command or MCP server.

Capability versions are per identifier. A consumer requesting version 1 may
accept a compatible later version only when its own negotiation rules say so.
Unknown identifiers or protocol versions must not be silently treated as
supported.

## Runtime metadata

Each archive contains:

```text
share/wineforge/capabilities.json
```

The delivery-side `*.runtime.json` embeds the identical document so Wineforge
can reject an unsuitable archive before extraction. The document includes the
engine ID, exact build target, protocol version, and target-specific provided
declarations. It is also included in `build-info.json` and therefore in the
build reference input digest.

The static probe is intentionally process-free:

```sh
./scripts/probe-capabilities.py ENGINE_ROOT
./scripts/probe-capabilities.py ENGINE_ROOT --id macos.window-isolation.strict
```

It reads only engine-owned metadata. It does not launch Wine, enumerate host
windows, inspect input, or request additional operating-system permissions.

## Recipe and profile policy

The engine contract states what can be implemented. Recipes and profiles state
what should be enabled for an application. Wineforge resolves those layers and
then checks the result against the selected engine's provided capabilities.
Unsupported required behavior should fail during preparation or launch rather
than being ignored.

For host bridging, engine metadata describes transports only. Native executable
selection, endpoint authorization, arguments, environment, tool permissions,
and lifecycle remain Wineforge runtime/profile responsibilities. Public engine
manifests cannot introduce arbitrary native commands.
