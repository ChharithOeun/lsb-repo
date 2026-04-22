# Windower 4 — LandSandBoat Auth Upgrade

Mirror of the xiloader 2.1.1 upgrade applied for Ashita's `ffxi-bootmod`, adapted for Windower 4's launcher layout.

## Why this is needed

Windower 4 ships with its own copy of xiloader (or references an external path via profile settings). If that copy is older than 2.1.0, LSB rejects the handshake with:
> Your xiloader is too old. Please update to version '2.1.x'.

Version gate is enforced in `server/src/login/auth_session.h`:
```c
constexpr std::array<uint8, 3> SupportedXiloaderVersion = { 2, 1, 0 };
```
and the error is raised in `auth_session.cpp` around line 159.

## Procedure

### 1. Locate Windower's xiloader
Typical locations to check, in order:

```
C:\Program Files (x86)\Windower4\xiloader.exe
C:\Windower4\xiloader.exe
%APPDATA%\Windower4\xiloader.exe
C:\Users\<user>\Windower4\xiloader.exe
```

Windower sometimes references an external xiloader rather than bundling one; look in `settings.xml` for a `<xiloader>` or `<boot>` path.

### 2. Verify version
```powershell
(Get-Item "<path>\xiloader.exe").VersionInfo | Select-Object FileVersion, ProductVersion
Get-FileHash "<path>\xiloader.exe" -Algorithm MD5
```
Anything below `2.1.0.0` must be replaced.

### 3. Back up the old binary
```powershell
$p = "<path>\xiloader.exe"
$ver = (Get-Item $p).VersionInfo.FileVersion
Copy-Item $p "$p.v$ver.bak"
```

### 4. Install xiloader 2.1.1
Source: LandSandBoat xiloader release on GitHub, tag `v2.1.1`.
Expected MD5: `44FE5F23BF76E4E847946B5B76F1E061`
Expected size: `1,072,128` bytes

```powershell
# If a clean copy already exists in ffxi-bootmod, just copy it across:
Copy-Item "F:\ffxi\Ashita\ffxi-bootmod\pol.exe" "<path>\xiloader.exe" -Force

# Verify
Get-FileHash "<path>\xiloader.exe" -Algorithm MD5
```

### 5. Update Windower profile
Open `Windower4\settings.xml`. Find the profile you use for the LSB server (likely named `Chharbot`, `Local`, `LSB`, or similar). Ensure:

```xml
<profile name="LSB">
    <server>127.0.0.1</server>
    <user>GUESTCL1</user>
    <!-- Do NOT store passwords in plain text. Enter at launch. -->
    <autologin>false</autologin>
    <hairpin>true</hairpin>
</profile>
```

If Windower's profile schema uses different element names, the concepts are the same: server address, username, autologin flag, hairpin flag. Passwords should be entered interactively — the control panel can inject `--password guestpass` via the launcher command line if the user explicitly opts in, same pattern as Ashita's `Private Server.xml`.

### 6. Smoke test
Launch Windower → select the LSB profile → click Play. Expected flow:
1. xiloader 2.1.1 opens a handshake to `127.0.0.1:54231`
2. Autologin (if enabled) or prompt for password
3. `Successfully logged in as GUESTCL1!`
4. Windower injects its runtime into the spawned `pol.exe`
5. Character-select screen renders

## Known differences from Ashita

Windower is generally more tolerant of the xiloader handoff than Ashita v4 because it uses a different injection strategy (CreateRemoteThread vs. boot-time DLL replacement). The "Failed to install Ashita! Error: 0" issue described in `ASHITA-INTEGRATION.md` does not usually occur with Windower — the xiloader upgrade alone is typically enough.

## Rollback

```powershell
$p = "<path>\xiloader.exe"
$bak = (Get-ChildItem "$p.v*.bak" | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
if ($bak) { Copy-Item $bak $p -Force; Write-Host "Rolled back to $($bak.Name)" }
```

## References
- xiloader releases: https://github.com/LandSandBoat/xiloader/releases
- LSB auth source: `server/src/login/auth_session.cpp`, `auth_session.h`
- Ashita equivalent upgrade: `docs/ASHITA-INTEGRATION.md`
- Master changelog: `docs/CHANGELOG.md`
