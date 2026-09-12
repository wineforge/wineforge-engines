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

Arbitrary key-chord rewriting and keyboard-to-scroll synthesis are deliberately
not claimed by these patches.  Implementing either safely requires a separately
versioned input-map format, text-entry and key-repeat semantics, conflict
handling, and focused driver tests.  Wineforge must reject or stage those rules
rather than silently approximating them with global macOS input injection.
