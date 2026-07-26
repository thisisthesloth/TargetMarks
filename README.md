# TargetMarks

A lightweight WoW 3.3.5 (Wrath of the Lich King) addon for private servers. Displays a row of raid target icons (skull, cross, moon, square, triangle, diamond, circle, star) — click one to instantly target whichever unit currently has that mark, no Tab-cycling required.

## Why

Tab-targeting through a pack of trash to find "the one with the skull" is slow and error-prone, especially with multiple similarly-named adds active at once (e.g. Garr's adds in Molten Core). TargetMarks turns raid mark icons into one-click target buttons.

## Features

- **One-click targeting** — click a mark icon, target whoever has it, right now.
- **Exact resolution, even with duplicate NPC names** — uses this server's backported `nameplateN` unit tokens to resolve the *specific* marked unit, not just "any unit with a matching name."
- **Combat-safe** — built on Blizzard's secure action button framework, so it works reliably mid-fight, not just out of combat.
- **Configurable** — adjustable icon spacing and scale, an enable/disable toggle, and a draggable/lockable position (unlock in settings to move the bar anywhere on screen).
- **Minimap button** — quick access to settings.

## How it works

TargetMarks tries several detection methods in order of reliability: your current target/focus/party/raid relations, then this core's `nameplateN` tokens (exact match, even for stacked duplicate-named units), falling back to nameplate-texture reading and name-based targeting for edge cases. All resolution happens outside combat and is cached into secure button attributes so the actual click still fires correctly during combat.

## Requirements

- 3.3.5 client on a private server whose core exposes `nameplateN` unit tokens (most modern Trinity-based cores do). Falls back gracefully if not, with reduced accuracy on duplicate-named units.

## Installation

1. Download or clone this repository.
2. Copy the `TargetMarks` folder into your `Interface/AddOns` directory.
3. Restart or reload your game client, and enable TargetMarks at the character select AddOns screen.
