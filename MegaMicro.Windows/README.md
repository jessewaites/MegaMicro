# MegaMicro for Windows

This is the Windows-native port of MegaMicro. It currently provides:

- read-only discovery for Creator Micro v1, Creator Micro 2, and Codex Micro;
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

The first milestone intentionally keeps hardware interaction read-only. RGB writes and key-event
handling will be enabled only after the raw VIA interface is qualified against a physical board.
