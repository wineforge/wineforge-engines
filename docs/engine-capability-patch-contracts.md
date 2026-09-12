# Engine capability patch contracts

This note records the narrow engine-facing interfaces used by Wineforge.  It is
not a capability manifest; manifests must advertise only patches that are
actually selected and built.

## Strict macOS window isolation

The version-scoped `winemac` patches add this DWORD-compatible registry value:

```text
HKCU\Software\Wine\Mac Driver\StrictWindowIsolation
HKCU\Software\Wine\AppDefaults\<executable>\Mac Driver\StrictWindowIsolation
```

The executable-specific value takes precedence through Wine's existing
`get_config_key` lookup.  A value beginning with `y`, `Y`, `t`, `T`, or `1`
enables the policy.  Missing or false values retain upstream behavior.

The later process-input patch also accepts
`WINEFORGE_STRICT_WINDOW_ISOLATION`.  When present, this process-local setting
overrides the registry policy without changing the prefix.

The policy only observes and orders `WineWindow` instances returned by the
process's own `NSApp`.  It does not use `CGWindowListCopyWindowInfo`, inspect
another process, install an event tap, or require macOS privacy permissions.

When active, the driver:

- orders visible floating Wine windows out when the application resigns active;
- immediately orders a floating Wine window out if it is shown while inactive;
- restores only windows that this policy hid; and
- cancels restoration when Wine performs a normal Win32-driven order-out.

The initial version intentionally limits the policy to floating windows.  It
does not infer undocumented macOS Space identifiers or alter ordinary top-level
Wine windows.

## Existing input configuration

Both pinned CrossOver source versions already expose per-executable Mac Driver
settings through the same AppDefaults lookup:

| Registry value | Supported behavior |
| --- | --- |
| `LeftCommandIsCtrl` | Map the left Command modifier to Windows Control |
| `RightCommandIsCtrl` | Map the right Command modifier to Windows Control |
| `LeftOptionIsAlt` | Map the left Option modifier to Windows Alt |
| `RightOptionIsAlt` | Map the right Option modifier to Windows Alt |
| `UsePreciseScrolling` | Preserve or quantize physical precision-scroll input |

These settings need no additional source patch.  Capability metadata may
advertise them when the selected source and target are known to contain this
implementation.

The Wineforge process-input patches expose the same behavior without prefix
mutation.  Environment values override registry values:

| Environment variable | Driver policy |
| --- | --- |
| `WINEFORGE_INPUT_LEFT_COMMAND_IS_CTRL` | `LeftCommandIsCtrl` |
| `WINEFORGE_INPUT_RIGHT_COMMAND_IS_CTRL` | `RightCommandIsCtrl` |
| `WINEFORGE_INPUT_LEFT_OPTION_IS_ALT` | `LeftOptionIsAlt` |
| `WINEFORGE_INPUT_RIGHT_OPTION_IS_ALT` | `RightOptionIsAlt` |
| `WINEFORGE_INPUT_PRECISE_SCROLLING` | `UsePreciseScrolling` |

Arbitrary key-chord rewriting is deliberately not claimed by these patches.
Implementing it safely requires modifier-state reconciliation so a remap cannot
leave an incorrect or stuck Windows modifier state.

## Keyboard-to-scroll rules version 1

The keyboard-scroll patches accept `WINEFORGE_INPUT_SCROLL_RULES_V1`.  The
process-local value is at most 2048 bytes and contains at most 32 rules:

```text
keycode:modifiers:x_scroll:y_scroll:allow_repeat[;...]
```

- `keycode` is a macOS virtual key code from 0 through 127.
- `modifiers` is a bit mask: Shift `1`, Control `2`, Option/Alt `4`, and
  Command `8`. It is evaluated after the side-specific modifier policy above.
- `x_scroll` and `y_scroll` are signed Wine scroll units from -1200 through
  1200, and cannot both be zero. A magnitude of 120 is one conventional wheel
  detent.
- `allow_repeat` is `0` or `1`.

Rules are evaluated in order and the first exact key-and-modifier match wins.
A matched key-down and its corresponding key-up are consumed. With
`allow_repeat=0`, repeated key-downs are also consumed without emitting more
scrolling. A fresh unmatched key-down clears any stale consumed-key state left
by a focus change before normal key handling continues.

Any malformed rule, empty field, excess rule, out-of-range value, or excess
input length disables the entire ruleset. The driver posts `MOUSE_SCROLL`
directly to the receiving Wine window at the source event's cursor position; it
does not synthesize an `NSEvent`, so the result cannot recursively match a rule.
It installs no global hook and needs no Input Monitoring permission.

Version 1 has an explicit always-active scope. The Mac driver cannot reliably
identify a focused Win32 text control at this seam, so launchers should require
a modifier for rules that use ordinary typing keys. Page, edge, drag-scroll,
and arbitrary chord-to-key output are not provided; they require separate
capabilities and lifecycle semantics rather than approximation here.
