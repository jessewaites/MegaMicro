# Creator Command Center for Windows

This is a Windows-native Creator Micro key-mapping app for Codex. The single desktop interface lets
you select any of the 16 physical keys, learn what that key currently sends, and bind it to a Codex
action or keyboard shortcut.

It includes:

- a visual 4x4 Creator Micro keymap;
- three editable layers and persistent profiles;
- one-click physical-key learning through a Windows global keyboard listener;
- actions to focus Codex, send a shortcut, or focus Codex and then send a shortcut;
- read-only Creator Micro v1, Creator Micro 2, and Codex Micro discovery;
- one self-contained `MegaMicro.exe` with no separate service or required .NET installation;
- no firmware flashing, keymap writes, or exclusive HID access.

## Use it

1. Connect the Creator Micro and open `MegaMicro.exe`.
2. Click a key in the on-screen 4x4 layout.
3. Click **Learn physical key**, then press that key on the Creator Micro.
4. Choose what it should do. For a shortcut action, click **Record output shortcut** and press the
   desired shortcut on a normal keyboard.
5. Click **Save binding**. The mapping works while Creator Command Center is running, including when
   minimized.

Bindings are saved in `%LOCALAPPDATA%\CreatorCommandCenter\bindings.json`.

## Build and run

```powershell
dotnet build .\MegaMicro.Windows.sln -c Release
dotnet run --project .\src\MegaMicro.Windows.App -c Release
```

Create the distributable one-file Windows application with:

```powershell
dotnet publish .\src\MegaMicro.Windows.App\MegaMicro.Windows.App.csproj `
  -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -o .\artifacts\single-exe
```

The resulting `MegaMicro.exe` contains the interface, binding engine, local agent service, hardware
probe, and VIA protocol check.

Run the dependency-free test harness with:

```powershell
dotnet run --project .\tests\MegaMicro.Windows.Tests -c Release
```

Hardware interaction remains read-only. Bindings translate the keyboard signals already produced by
the Creator Micro, so the app does not rewrite or flash the device.

## Send an agent-state event

With MegaMicro running, PowerShell can send a test event:

```powershell
Invoke-RestMethod `
  -Method Post `
  -Uri http://127.0.0.1:48802/state `
  -ContentType application/json `
  -Body '{"source":"codex","state":"working","session":"test-agent","cwd":"C:\TestProject"}'
```

Canonical states are `idle`, `thinking`, `coding`, `waiting`, `success`, and `error`. Friendly
aliases are accepted, including `working`, `running`, `complete`, `done`, and `needs_input`.
