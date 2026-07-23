# MegaMicro for Windows

This is the Windows-native port of MegaMicro. It currently provides:

- read-only discovery for Creator Micro v1, Creator Micro 2, and Codex Micro;
- an opt-in VIA protocol-version handshake that changes no device settings;
- a loopback-only agent-state API at `http://127.0.0.1:48802`;
- a fail-open provider hook bridge;
- a native WPF status dashboard;
- no firmware flashing and no exclusive HID access.

## Build and run

```powershell
dotnet build .\MegaMicro.Windows.sln -c Release
dotnet run --project .\src\MegaMicro.Windows.App -c Release
```

Run the dependency-free test harness with:

```powershell
dotnet run --project .\tests\MegaMicro.Windows.Tests -c Release
```

Hardware interaction remains read-only. The VIA handshake sends only the public protocol-version
request. RGB writes and key-event handling will be enabled only after the raw interface is qualified
across representative physical boards and firmware revisions.
