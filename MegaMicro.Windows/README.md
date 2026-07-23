# MegaMicro for Windows

This is the Windows-native port of MegaMicro. It currently provides:

- read-only discovery for Creator Micro v1, Creator Micro 2, and Codex Micro;
- an opt-in VIA protocol-version handshake that changes no device settings;
- a loopback-only agent-state API at `http://127.0.0.1:48802`;
- a native WPF status dashboard;
- no firmware flashing and no exclusive HID access.

The next interface direction is documented in
[`docs/design/CREATOR_COMMAND_CENTER.md`](docs/design/CREATOR_COMMAND_CENTER.md).

## Build and run

```powershell
dotnet build .\MegaMicro.Windows.sln -c Release
dotnet run --project .\src\MegaMicro.Windows.App -c Release
```

Create the distributable one-file Windows application with:

```powershell
dotnet publish .\src\MegaMicro.Windows.App\MegaMicro.Windows.App.csproj `
  -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -o .\artifacts\single-file
```

The resulting `MegaMicro.exe` contains the interface, local agent service, hardware probe, and VIA
protocol check. It does not require a separate DLL folder or a preinstalled .NET runtime.

Run the dependency-free test harness with:

```powershell
dotnet run --project .\tests\MegaMicro.Windows.Tests -c Release
```

Hardware interaction remains read-only. The VIA handshake sends only the public protocol-version
request. RGB writes and key-event handling will be enabled only after the raw interface is qualified
across representative physical boards and firmware revisions.

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
