# Place-DesktopIcon.ps1 - move a desktop icon by name to a screen position.
# Usage: pwsh -File Place-DesktopIcon.ps1 -Name "MailScrub" -Corner LowerRight
param([string]$Name = 'MailScrub', [string]$Corner = 'LowerRight')
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text; using System.Collections.Generic;
public static class DeskIcons {
  [DllImport("user32.dll")] static extern IntPtr FindWindow(string c, string w);
  [DllImport("user32.dll")] static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string w);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, uint pid);
  [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr a, uint s, uint t, uint p);
  [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr h, IntPtr a, uint s, uint t);
  [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr h, IntPtr a, byte[] b, uint s, out uint w);
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, uint s, out uint r);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  const uint LVM_GETITEMCOUNT=0x1004, LVM_GETITEMTEXTW=0x1073, LVM_SETITEMPOSITION=0x100F, LVM_GETITEMPOSITION=0x1010;
  [StructLayout(LayoutKind.Sequential)] struct LVITEM { public uint mask; public int iItem; public int iSubItem; public uint state; public uint stateMask; public IntPtr pszText; public int cchTextMax; public int iImage; public IntPtr lParam; public int iIndent; public int iGroupId; public uint cColumns; public IntPtr puColumns; public IntPtr piColFmt; public int iGroup; }
  public static IntPtr FindListView() {
    IntPtr progman = FindWindow("Progman", null);
    IntPtr dv = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
    if (dv == IntPtr.Zero) {
      EnumWindows((h, l) => { if (dv == IntPtr.Zero) { IntPtr w = FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null); if (w != IntPtr.Zero) dv = w; } return true; }, IntPtr.Zero);
    }
    return dv == IntPtr.Zero ? IntPtr.Zero : FindWindowEx(dv, IntPtr.Zero, "SysListView32", null);
  }
  public static List<string> GetNames(IntPtr lv) {
    var names = new List<string>();
    int n = (int)SendMessage(lv, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero);
    uint pid; GetWindowThreadProcessId(lv, out pid);
    IntPtr hp = OpenProcess(0x38, false, pid);
    uint sz = (uint)Marshal.SizeOf(typeof(LVITEM)); uint bufsz = 1024;
    IntPtr rItem = VirtualAllocEx(hp, IntPtr.Zero, sz, 0x1000, 4);
    IntPtr rText = VirtualAllocEx(hp, IntPtr.Zero, bufsz, 0x1000, 4);
    for (int i = 0; i < n; i++) {
      var it = new LVITEM { mask = 1, iItem = i, iSubItem = 0, pszText = rText, cchTextMax = (int)bufsz/2 };
      IntPtr local = Marshal.AllocHGlobal((int)sz); Marshal.StructureToPtr(it, local, false);
      byte[] b = new byte[sz]; Marshal.Copy(local, b, 0, (int)sz); Marshal.FreeHGlobal(local);
      uint w; WriteProcessMemory(hp, rItem, b, sz, out w);
      SendMessage(lv, LVM_GETITEMTEXTW, (IntPtr)i, rItem);
      byte[] tb = new byte[bufsz]; uint r; ReadProcessMemory(hp, rText, tb, bufsz, out r);
      string s = Encoding.Unicode.GetString(tb); int z = s.IndexOf('\0'); names.Add(z >= 0 ? s.Substring(0, z) : s);
    }
    VirtualFreeEx(hp, rItem, 0, 0x8000); VirtualFreeEx(hp, rText, 0, 0x8000); CloseHandle(hp);
    return names;
  }
  public static void SetPos(IntPtr lv, int idx, int x, int y) {
    SendMessage(lv, LVM_SETITEMPOSITION, (IntPtr)idx, (IntPtr)((y << 16) | (x & 0xFFFF)));
  }
}
"@
$lv = [DeskIcons]::FindListView()
if ($lv -eq [IntPtr]::Zero) { Write-Error 'Desktop list view not found'; exit 1 }
$names = [DeskIcons]::GetNames($lv)
$idx = $names.IndexOf($Name)
if ($idx -lt 0) { Write-Error "Icon '$Name' not found. Icons: $($names -join ', ')"; exit 1 }
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
switch ($Corner) {
  'LowerRight' { $x = $wa.Right - 110;  $y = $wa.Bottom - 110 }
  'LowerLeft'  { $x = $wa.Left + 10;    $y = $wa.Bottom - 110 }
  'UpperRight' { $x = $wa.Right - 110;  $y = $wa.Top + 10 }
  default      { $x = $wa.Left + 10;    $y = $wa.Top + 10 }
}
[DeskIcons]::SetPos($lv, $idx, $x, $y)
"Moved '$Name' (item $idx of $($names.Count)) to $x,$y on primary screen ($($wa.Width)x$($wa.Height))"
