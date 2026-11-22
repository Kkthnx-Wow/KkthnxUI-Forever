# LibActionButtonKit-1.0

Secure action buttons for World of Warcraft addons. One library for retail and
classic clients, built from Blizzard's own action button code and written to be
read.

This is an early build, in use by KkthnxUI on the WoW Forever client. Buttons,
paging, drawing, range, usable tint, cooldowns, secure casting and secure drag
and drop are tested there in game. Flyouts are checked against Blizzard's source
but not yet tested with a known flyout. Each section marks what is verified
against Blizzard source, what is verified in game, and what is still open.

## Why it exists

An action bar addon needs buttons that cast in combat, page with forms and
vehicles, and show cooldowns, range, usability, counts and procs. The game only
lets secure code take those actions, so the hard part is keeping every path that
leads to a cast free of addon taint while the visible state is still drawn by
addon code.

LibActionButtonKit does that with three rules.

1. Secure code decides what a click does. The library never computes the action
   slot for a click in addon code. Blizzard's secure click handler does it from
   attributes.
2. Addon code only draws. It reads the same attributes to know what to draw and
   never writes a field that Blizzard code reads.
3. Every client difference is detected by asking for the API, never by checking
   the client name.

## Goals

- Retail (12.x and later) and classic clients from one code path.
- Main bar paging for stances, forms, stealth, possess, vehicle and override bars.
- Fixed page bars for the extra bars.
- Cooldowns, charges and loss of control, safe with 12.x secret values.
- Usable, out of mana and out of range tints, driven by the game's events.
- Counts, macro names, hotkeys, equipped border, checked state, attack and auto
  repeat flash.
- Proc glow state, handed to the host through `GlowShown` and `GlowHidden`
  callbacks. The library does not call the game's own alert manager, because
  that is a shared Blizzard table and a call from addon code would write into it.
- Empty slot grid, drag and drop, and the action bar lock.
- Flyouts.
- A small, documented API with callbacks so the host addon styles everything.

## Non goals

- Pet, stance and possess buttons. Those stay Blizzard's own buttons in the host
  addon, because the game drives them well and they have no paging.
- Any styling. The library creates plain regions and exposes them. Borders, fonts
  and textures belong to the host.
- Masque or other skin systems in the first release.
- Spell, item and macro button types that do not go through an action slot. They
  can come later if a host needs them.

## Supported clients and detection

| Feature | Detected by | Fallback |
|---|---|---|
| Usable updates | `ACTION_USABLE_CHANGED` event exists | `ACTIONBAR_UPDATE_USABLE` and a full refresh |
| Range updates | `C_ActionBar.EnableActionRangeCheck` | Poll `IsActionInRange` on a throttle while a target exists |
| Cooldown duration objects | `C_ActionBar.GetActionCooldownDuration` and `Cooldown.SetCooldownFromDurationObject` | `GetActionCooldown` and `SetCooldown` |
| Proc glow state | `C_SpellActivationOverlay.IsSpellOverlayed` or `IsSpellOverlayed` | Events only, no state on refresh |
| Flyouts | `SpellFlyout` | Flyout actions show their icon and do nothing on click |
| Press and hold spells | `C_Spell.IsPressHoldReleaseSpell` | Off |

Every row is checked once at load. A missing API turns its feature off and the
rest of the library keeps working.

On Forever the action functions exist only under `C_ActionBar`, except
`GetActionInfo`, `PickupAction` and `PlaceAction`, which are globals only
(checked against the forever branch of BlizzardInterfaceResources). Core.lua
picks the `C_ActionBar` function first and the global second, and all 24
entries resolve on Forever 1.60.1 in game. Every event the library registers is
in that branch's event list.

## Verified facts this design rests on

Source references are to the public mirror of Blizzard's UI code,
`Gethe/wow-ui-source`. The Forever client has its own branch there, named
`forever`.

### The secure click (verified in source, forever branch)

`Blizzard_FrameXML/SecureTemplates.lua`

- `SECURE_ACTIONS.action` resolves the slot with `self:CalculateAction(button)`.
- For a button whose ID is above 0, the slot is
  `self:GetID() + ((page - 1) * NUM_ACTIONBAR_BUTTONS)`, with the page read from
  the `actionpage` attribute. Without an ID it uses the `action` attribute.
- Attributes are read through `SecureButton_GetModifiedAttribute`, which also
  checks the parent when the button has `useparent-<name>` set.
- A flyout action calls `(self.popup or SpellFlyout):Toggle(self, flyoutId, ...)`.
  Anything else hides the flyout and calls `UseAction`.
- `SecureActionButton_OnClick(self, inputButton, down, isKeyPress, isSecureAction)`
  fires on key down when `useOnKeyDown` (or the `ActionButtonUseKeyDown` CVar)
  says so, and handles press and hold release through `typerelease`.

### Paging and restricted code (verified in source, forever branch)

`Blizzard_RestrictedAddOnEnvironment/RestrictedFrames.lua`,
`SecureHandlers.lua`, `SecureStateDriver.lua`

- `RegisterStateDriver(frame, "page", conditions)` writes `state-page`. The bar's
  `_onstate-page` snippet runs in restricted code and is not blocked in combat.
- Frame handles in restricted code may call `SetAttribute` (names not starting
  with an underscore), `GetAttribute`, `GetID`, `ChildUpdate` and `GetFrameRef`.
- `ChildUpdate(id, message)` runs each child's `_childupdate-<id>` attribute.
- `SecureHandlerWrapScript` can wrap `OnDragStart` and `OnReceiveDrag` on a
  protected button, and a drag snippet may return a pickup kind such as
  `"action", slot`. Wrapping has to be set up out of combat.

### Button behaviour (verified in source, live, classic era and forever)

`Blizzard_ActionBar/Shared/ActionButton.lua` is shared by retail and classic and
is byte for byte the same on classic era and classic.

- Usable state comes from `ACTION_USABLE_CHANGED`, whose payload lists
  `slot, usable, noMana`. The old `ACTIONBAR_UPDATE_USABLE` is commented out.
- Range comes from `ACTION_RANGE_CHECK_UPDATE` after
  `C_ActionBar.EnableActionRangeCheck(slot, true)`. Blizzard does not count how
  many buttons share a slot, so one button can switch the check off for another.
  LibActionButtonKit counts references per slot.
- Cooldowns read `C_ActionBar.GetActionCooldown`, `GetActionCharges` and
  `GetActionLossOfControlCooldownInfo`, then call `SetCooldown`.
- Counts use `C_ActionBar.GetActionDisplayCount`.
- Proc glow goes through `ActionButtonSpellAlertManager:ShowAlert(button)` and
  `HideAlert(button)`, driven by `SPELL_ACTIVATION_OVERLAY_GLOW_SHOW` and `_HIDE`.

### Still open

- Flyouts in game. Blizzard's `SpellFlyout` is not used, because `Toggle` calls
  back into the owner button (`TogglePopup` and its popup fields), which on an
  addon button are addon values, so the shared flyout's state could be written
  under taint. The library opens its own secure flyout instead (Flyout.lua).
  It closes on its own spell, on any other library button's action, on a page
  change and when its opener hides, all from restricted code. It does not yet
  close on a click elsewhere on the screen or on Escape. Checked in the forever
  branch source: a numeric `spell` attribute casts through `CastSpellByID`,
  restricted snippets have `GetActionInfo` (flyout ids pass its scrubber),
  `HasAction`, `IsModifiedClick` and `tonumber`, `OnHide` and `OnClick` can be
  wrapped, and a click snippet returning false stops the click. It still needs a
  character with a known flyout to test in game. Flyout buttons show icon and
  tooltip only, no cooldown or usable tint yet.
- Whether cooldown values turn secret in combat on Forever. It no longer
  matters for drawing there. Forever 1.60.1 has `GetActionCooldownDuration`,
  `GetActionChargeDuration`, `GetActionLossOfControlCooldownDuration` and
  `SetCooldownFromDurationObject`, so the library takes the duration object path
  and never compares a cooldown value. Checked live out of combat. A 90 second
  cooldown and the global cooldown both draw, nothing was secret,
  `GetActionChargeDuration` returns nil for a spell without charges, and the
  other two getters always return an object, zero length when idle. The
  `SetCooldown` fallback compares values and is only reached on clients without
  duration objects, which also have no secret values so far.
- The exact list of macro conditions `SecureCmdOptionParse` accepts on each
  client. The paging driver is read from the client at runtime instead of being
  hard coded, which the host already does.

## Architecture

```
LibActionButtonKit-1.0/
  LibActionButtonKit-1.0.xml   load order
  Core.lua               LibStub registration, version, feature detection, callbacks
  Button.lua             button creation and its regions
  Secure.lua             attributes, paging snippets, drag wraps
  Update.lua             every visual update, one function per concern
  Events.lua             one event frame, slot index, dispatch
  Flyout.lua             the library's own secure flyout
  README.md              this file
```

### Ownership

| Concern | Owner | Why |
|---|---|---|
| Which slot a click uses | Secure code | Computed by `CalculateAction` from `ID` and `actionpage` |
| Page changes | Secure code | `_onstate-page` sets `actionpage` on the bar |
| Which slot is drawn | Addon code | Same formula, run when `actionpage` changes |
| Icons, tints, counts, cooldowns | Addon code | Drawn only, never read by Blizzard |
| Drag and drop | Secure code | Wrapped `OnDragStart` and `OnReceiveDrag` |
| Key bindings | Host addon | Override bindings that click the button |

### The button

A `CheckButton` created with `SecureActionButtonTemplate` only. The library
creates its own regions (`Icon`, `Cooldown`, `ChargeCooldown`,
`LossOfControlCooldown`, `Count`, `HotKey`, `Name`, `Flash`, `Border`,
`NewAction`) instead of inheriting `ActionButtonTemplate`. That template carries
Blizzard's mixin and an `OnAttributeChanged` script that runs Blizzard's flyout
code on our frame, which is exactly the kind of shared state the library must not
touch. Building the regions also makes the button identical on every client.

Library state lives in a private table keyed by button, not in fields on the
button, so nothing the secure click reads is ever written by addon code.

### Paging

The host gives a bar its driver conditions, the library sets

- each button's ID to its index on the bar,
- `useparent-actionpage` on each button,
- an `_onstate-page` snippet on the bar that turns the state into a page and
  writes `actionpage`.

An `OnAttributeChanged` hook on the bar sees the new page and redraws the buttons
from addon code. That hook only reads.

Fixed page bars set `actionpage` once.

### Events

One frame, registered once, with an index from slot to buttons. A slot event
touches only the buttons showing that slot. Broad events (bindings, page,
combat start and end) walk the active buttons once.

### Updates

`Update.lua` has one function per concern (`Icon`, `Cooldown`, `Count`, `Usable`,
`Range`, `Checked`, `Flash`, `Glow`, `Text`, `Equipped`, `Grid`). Each takes a
button, reads its slot, and draws. `Refresh(button)` runs them all. Every function
that can receive a secret value passes it straight to a widget method that
accepts secrets and never compares or does arithmetic on it.

## Public API (draft)

```lua
local Kit = LibStub("LibActionButtonKit-1.0")

-- A bar is any protected frame that inherits SecureHandlerStateTemplate.
-- name is required, because the flyout tracks its opener by name.
local button = Kit:CreateButton(bar, index, name, options)

-- Main bar paging. conditions is a macro conditional string ending in a page.
Kit:SetPaging(bar, conditions)

-- Extra bars on a fixed page.
Kit:SetFixedPage(bar, page)

-- Which way the bar's flyouts open: "UP", "DOWN", "LEFT" or "RIGHT".
Kit:SetFlyoutDirection(bar, direction)

-- Key presses fire on the press (true), the release (false) or as the game
-- setting says (nil). Mouse clicks always fire on the release.
Kit:SetKeyDown(button, value)

-- Bind keys with the virtual mouse button "Keybind", so the library can tell a
-- key press from a mouse click.
SetOverrideBindingClick(owner, false, key, button:GetName(), "Keybind")

-- Per button options. Safe in combat, options only change what is drawn.
Kit:SetOptions(button, options)

-- Redraw every button, after a host setting changes.
Kit:RefreshAll()

-- The action slot a button shows right now, or nil before its bar has a page.
local slot = Kit:GetSlot(button)

-- Every library button.
for button in Kit:IterateButtons() do end

-- The button whose flyout is open, or nil, and whether the pointer is on one
-- of the flyout's buttons. For hosts that fade bars on mouseover.
local opener = Kit:GetFlyoutOpener()
local over = Kit:IsMouseOverFlyout()

-- Callbacks for the host to style and react.
Kit.RegisterCallback(host, "ButtonCreated", function(event, button) end)
Kit.RegisterCallback(host, "ButtonUpdated", function(event, button) end)
Kit.RegisterCallback(host, "GlowShown", function(event, button) end)
Kit.RegisterCallback(host, "GlowHidden", function(event, button) end)
Kit.RegisterCallback(host, "FlyoutButtonCreated", function(event, button) end)
Kit.RegisterCallback(host, "FlyoutShown", function(event, opener) end)
Kit.RegisterCallback(host, "FlyoutHidden", function(event, opener) end)
```

Options

| Key | Default | Meaning |
|---|---|---|
| `showGrid` | `false` | Show empty slots |
| `rangeTint` | `"icon"` | `"icon"`, `"hotkey"` or `false` |
| `colors.range` | `{0.8, 0.1, 0.1}` | Out of range tint |
| `colors.mana` | `{0.5, 0.5, 1.0}` | Not enough power tint |
| `colors.unusable` | `{0.4, 0.4, 0.4}` | Unusable tint |
| `showCount` | `true` | Count and charges text |
| `showMacroName` | `true` | Macro name text |
| `showHotKey` | `true` | Hotkey text |
| `bindingName` | `nil` | Binding command whose key is shown as the hotkey |

## Taint rules

- Never write a field on a Blizzard table or frame. Never hook a Blizzard action
  bar function or use Blizzard's action button event frames.
- Never write a field on a library button that secure code reads. Library state
  lives in private tables.
- Every setting that changes attributes, IDs, parents, points or wraps runs out
  of combat. A change asked for in combat is queued and applied on
  `PLAYER_REGEN_ENABLED`.
- No comparison or arithmetic on values that may be secret.

## Testing

Each feature is checked in game on the Forever client before the next one starts.

1. Bar 1 shows icons, clicks cast, key bindings fire.
2. Paging on a druid in each form, a rogue in stealth, and a vehicle or possess
   bar where one is reachable.
3. Cooldowns, charges and loss of control on a spell, an item and a potion.
4. Usable, mana and range tints against a target moving in and out of range.
5. Drag a spell in, swap two slots, drag one out, with the bar locked and
   unlocked, in and out of combat.
6. Proc glow on a class proc.
7. Flyouts, mount and class, in and out of combat.
8. The host addon's taint scan after each step, plus a reload loop with an error
   catcher open.

## Credits

Blizzard's UI source is the reference for every behaviour. LibActionButton-1.0 by
Hendrik Leppkes was read for how established addons approach the same problems.
No code from it is used.

## License

Part of KkthnxUI and distributed with it under the same terms.
