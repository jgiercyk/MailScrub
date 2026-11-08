# MailScrubGui.ps1 - WinForms front end for mailscrub.py
# Run:  pwsh -NoProfile -STA -File MailScrubGui.ps1   (Windows PowerShell 5.1 also works)
# All mail logic lives in the engine; this file only edits rules.yaml through the engine's CLI,
# shows engine output, and manages the two scheduled tasks.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Engine   = Join-Path $Here 'mailscrub.py'
$CredFile = Join-Path $Here 'credentials.json'
$LogFile  = Join-Path $Here 'scrub.log'
$Python   = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $Python) { [System.Windows.Forms.MessageBox]::Show('python.exe not found on PATH'); exit 1 }

$TaskScan = 'MailScrub Scan'; $TaskPurge = 'MailScrub Purge'
$PurgeTime = '3am'
$LogTailLines = 400
$PumpIntervalMs = 400

# ---------- engine bridge ----------
function New-TempJson { Join-Path $env:TEMP ("mailscrub_{0}.json" -f [guid]::NewGuid().ToString('N')) }
function Invoke-Engine {
    param([string[]]$EngineArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Python
    $psi.Arguments = ('-X utf8 "{0}" {1}' -f $Engine, ($EngineArgs -join ' '))
    $psi.WorkingDirectory = $Here
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    # read stderr asynchronously so a chatty engine cannot deadlock on a full pipe
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $errTask.Result }
}
function Invoke-EngineJson {
    param([string]$Command, $Payload)
    $tmp = New-TempJson
    try {
        $Payload | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
        return Invoke-Engine @($Command, ('"{0}"' -f $tmp))
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}
function Get-Config {
    $r = Invoke-Engine @('config-get')
    if ($r.Code -ne 0) { throw "config-get failed: $($r.Out)$($r.Err)" }
    $r.Out | ConvertFrom-Json
}

# ---------- helpers ----------
$A_TL  = [System.Windows.Forms.AnchorStyles]'Top,Left'
$A_TLR = [System.Windows.Forms.AnchorStyles]'Top,Left,Right'
$A_ALL = [System.Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
$A_BL  = [System.Windows.Forms.AnchorStyles]'Bottom,Left'
$A_BLR = [System.Windows.Forms.AnchorStyles]'Bottom,Left,Right'

function New-Label($text, $x, $y, $w = 140) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = "$x,$y"; $l.Size = "$w,20"; $l.Anchor = $A_TL; $l
}
function New-Text($x, $y, $w, $anchor = $A_TLR) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = "$x,$y"; $t.Size = "$w,23"; $t.Anchor = $anchor; $t
}
function New-Check($text, $x, $y, $w = 420) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text; $c.Location = "$x,$y"; $c.Size = "$w,22"; $c.Anchor = $A_TL; $c
}
function New-Num($x, $y, $min, $max, $dec = 0, $w = 80) {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Location = "$x,$y"; $n.Size = "$w,23"; $n.Minimum = $min; $n.Maximum = $max
    $n.DecimalPlaces = $dec; $n.Increment = $(if ($dec) { 0.05 } else { 1 }); $n.Anchor = $A_TL; $n
}
function New-Button($text, $x, $y, $w = 120, $anchor = $A_TL) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = "$x,$y"; $b.Size = "$w,28"; $b.Anchor = $anchor; $b
}
$CheckColumns = @('not_bulk', 'bulk_only')
function New-Grid($x, $y, $w, $h, [string[]]$cols) {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Location = "$x,$y"; $g.Size = "$w,$h"; $g.Anchor = $A_ALL
    $g.AllowUserToAddRows = $true; $g.AllowUserToDeleteRows = $true
    $g.AutoSizeColumnsMode = 'Fill'; $g.RowHeadersVisible = $false
    foreach ($c in $cols) {
        if ($c -in $CheckColumns) {
            $col = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
            $col.FillWeight = 25
        } else { $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn }
        $col.Name = $c; $col.HeaderText = $c; [void]$g.Columns.Add($col)
    }
    $g
}

# ---------- form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'MailScrub'; $form.Size = '900,660'; $form.MinimumSize = '760,540'
$form.StartPosition = 'CenterScreen'

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = '8,8'; $tabs.Size = '868,568'; $tabs.Anchor = $A_ALL
$form.Controls.Add($tabs)

$status = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel 'Ready'
[void]$status.Items.Add($statusLabel); $form.Controls.Add($status)
function Set-Status($t) { $statusLabel.Text = $t; $form.Refresh() }

function New-Tab($title) { $p = New-Object System.Windows.Forms.TabPage $title; $p.Padding = '8,8,8,8'; [void]$tabs.TabPages.Add($p); $p }

# ===== Connection =====
$tConn = New-Tab 'Connection'
$tConn.Controls.AddRange(@(
    (New-Label 'IMAP server' 16 24), ($txHost = New-Text 160 22 420),
    (New-Label 'Port' 16 56),        ($nuPort = New-Num 160 54 1 65535),
    (New-Label 'Email address' 16 88), ($txUser = New-Text 160 86 420),
    (New-Label 'Password' 16 120),   ($txPass = New-Text 160 118 420)
))
$txPass.UseSystemPasswordChar = $true
$lbPassState = New-Label '' 16 146 600; $lbPassState.Size = '640,20'; $lbPassState.Anchor = $A_TLR
$btnTest = New-Button 'Save and test connection' 160 172 180
$btnSaveConn = New-Button 'Save credentials' 350 172 140
$lbConnNote = New-Label 'The password is encrypted with Windows DPAPI for your account and stored in credentials.json. Leave the box empty to keep the stored password.' 16 214 600
$lbConnNote.Size = '640,40'; $lbConnNote.Anchor = $A_TLR
$tConn.Controls.AddRange(@($lbPassState, $btnTest, $btnSaveConn, $lbConnNote))

# ===== Rules =====
$tRules = New-Tab 'Rules'
$lbAllow = New-Label 'ALLOW rules (win over block rules and heuristics; the language filter still runs first). from/subject are regexes; both must match when both given. not_bulk = only if no list headers.' 8 8 836
$lbAllow.Anchor = $A_TLR
$gAllow = New-Grid 8 30 836 200 @('from', 'subject', 'not_bulk')
$lbBlock = New-Label 'BLOCK rules (quarantine on match). bulk_only = only when the message has list headers or unsubscribe wording, so support replies and shipping notices from that sender still get through.' 8 240 836
$gBlock = New-Grid 8 262 836 200 @('from', 'subject', 'bulk_only', 'note')
$gBlock.Anchor = $A_BLR
$btnRulesSave = New-Button 'Save rules' 8 490 120 $A_BL
$btnRulesReload = New-Button 'Reload' 136 490 100 $A_BL
$tRules.Controls.AddRange(@($lbAllow, $gAllow, $lbBlock, $gBlock, $btnRulesSave, $btnRulesReload))

# ===== Filters =====
$tFilt = New-Tab 'Filters'
$gbH = New-Object System.Windows.Forms.GroupBox; $gbH.Text = 'Heuristics (new list mail you have never seen). Each signal adds its weight; the message is quarantined when the total reaches the threshold.'
$gbH.Location = '12,10'; $gbH.Size = '820,200'; $gbH.Anchor = $A_TLR
$ckHEnabled  = New-Check 'Enable heuristics' 16 24
$ckListUnsub = New-Check 'List-Unsubscribe header present' 16 48 300;  $nuWListUnsub = New-Num 330 48 0 10 0 60
$ckPrecBulk  = New-Check 'Precedence: bulk / list / junk' 16 72 300;   $nuWPrec = New-Num 330 72 0 10 0 60
$lbListId    = New-Label 'List-Id header present (always on)' 36 98 290; $nuWListId = New-Num 330 96 0 10 0 60
$ckSubConf   = New-Check '"Confirm your subscription" style subject' 16 120 300; $nuWSubConf = New-Num 330 120 0 10 0 60
$ckUnsubLink = New-Check 'Unsubscribe / opt-out wording in body' 16 144 300; $nuUnsubW = New-Num 330 144 0 10 0 60
$lbWeight    = New-Label 'weight' 396 50 60
$lbMin = New-Label 'Quarantine when score reaches' 480 48 200; $nuMin = New-Num 680 46 1 10 0 60
$gbH.Controls.AddRange(@($ckHEnabled, $ckListUnsub, $nuWListUnsub, $ckPrecBulk, $nuWPrec, $lbListId, $nuWListId, $ckSubConf, $nuWSubConf, $ckUnsubLink, $nuUnsubW, $lbWeight, $lbMin, $nuMin))

$gbL = New-Object System.Windows.Forms.GroupBox; $gbL.Text = 'Language'
$gbL.Location = '12,220'; $gbL.Size = '820,120'; $gbL.Anchor = $A_TLR
$ckLang = New-Check 'Enable language filter (runs before allow rules; learned allows still win)' 16 24 600
$lbAllowed = New-Label 'Allowed languages (ISO codes, comma separated)' 16 52 280; $txLangs = New-Text 300 50 160 $A_TL
$lbConf = New-Label 'Minimum confidence' 16 84 160; $nuConf = New-Num 180 82 0.5 1 2
$lbAct = New-Label 'Action' 300 84 50
$cbLangAct = New-Object System.Windows.Forms.ComboBox; $cbLangAct.Location = '350,82'; $cbLangAct.Size = '120,23'
$cbLangAct.DropDownStyle = 'DropDownList'; [void]$cbLangAct.Items.AddRange(@('delete', 'quarantine'))
$lbActNote = New-Label '"delete" moves to the Trash folder when one exists (see Settings).' 480 84 330
$gbL.Controls.AddRange(@($ckLang, $lbAllowed, $txLangs, $lbConf, $nuConf, $lbAct, $cbLangAct, $lbActNote))

$gbU = New-Object System.Windows.Forms.GroupBox; $gbU.Text = 'Unsubscribe'
$gbU.Location = '12,350'; $gbU.Size = '820,70'; $gbU.Anchor = $A_TLR
$ckUnsub = New-Check 'Send RFC 8058 one-click unsubscribe for mail being removed (header-based only; body links are never clicked)' 16 24 780
$gbU.Controls.Add($ckUnsub)
$btnFiltSave = New-Button 'Save filters' 12 490 120 $A_BL
$tFilt.Controls.AddRange(@($gbH, $gbL, $gbU, $btnFiltSave))

# ===== Settings =====
$tSet = New-Tab 'Settings'
$lbSrc = New-Label 'Source folder' 16 24;        $txSrc = New-Text 180 22 240 $A_TL
$lbQF  = New-Label 'Quarantine folder' 16 56;   $txQF  = New-Text 180 54 240 $A_TL
$lbTr  = New-Label 'Trash folder' 16 88;        $txTr  = New-Text 180 86 240 $A_TL
$ckTrash = New-Check 'Move "delete" verdicts to the Trash folder instead of deleting permanently' 440 86 400
$lbRet = New-Label 'Quarantine retention (days)' 16 120 160; $nuRet = New-Num 180 118 1 365
$ckLearn = New-Check 'Learn from restores: a message moved back from Quarantine to the source folder allow-lists its sender' 16 150 800
$ckDry = New-Check 'DRY RUN - report only, never move or delete mail' 16 176 500
$ckDry.ForeColor = 'DarkRed'
$ckRescan = New-Check 'Always re-scan messages previously judged keep (slow; rules changes already trigger this automatically)' 16 202 800
$gbTask = New-Object System.Windows.Forms.GroupBox; $gbTask.Text = 'Windows Scheduled Tasks (the task is the source of truth; this panel shows its live state)'
$gbTask.Location = '12,240'; $gbTask.Size = '820,110'; $gbTask.Anchor = $A_TLR
$lbEvery = New-Label 'Scan every (minutes, used by Install)' 16 28 230; $nuEvery = New-Num 250 26 5 1440
$btnTaskInstall = New-Button 'Install / update tasks' 16 62 160
$btnTaskRemove = New-Button 'Remove tasks' 186 62 120
$lbTaskState = New-Label '' 320 28 480; $lbTaskState.Size = '480,70'; $lbTaskState.Anchor = $A_TLR
$gbTask.Controls.AddRange(@($lbEvery, $nuEvery, $btnTaskInstall, $btnTaskRemove, $lbTaskState))
$btnSetSave = New-Button 'Save settings' 12 490 120 $A_BL
$tSet.Controls.AddRange(@($lbSrc, $txSrc, $lbQF, $txQF, $lbTr, $txTr, $ckTrash, $lbRet, $nuRet, $ckLearn, $ckDry, $ckRescan, $gbTask, $btnSetSave))

# ===== Run =====
$tRun = New-Tab 'Run'
$btnSurvey = New-Button 'Survey inbox' 8 8 120
$btnScan   = New-Button 'Scan now' 136 8 120
$btnDigest = New-Button 'New-sender digest' 264 8 140
$btnPurge  = New-Button 'Purge quarantine' 412 8 130
$btnReview = New-Button 'Review flagged...' 550 8 130
$btnReview.Font = New-Object System.Drawing.Font($btnReview.Font, [System.Drawing.FontStyle]::Bold)
$btnLog    = New-Button 'Show log' 688 8 80
$btnClear  = New-Button 'Clear' 776 8 60
$txOut = New-Object System.Windows.Forms.TextBox
$txOut.Location = '8,44'; $txOut.Size = '836,480'; $txOut.Anchor = $A_ALL
$txOut.Multiline = $true; $txOut.ScrollBars = 'Both'; $txOut.ReadOnly = $true
$txOut.Font = New-Object System.Drawing.Font('Consolas', 9); $txOut.WordWrap = $false
$tRun.Controls.AddRange(@($btnSurvey, $btnScan, $btnDigest, $btnPurge, $btnReview, $btnLog, $btnClear, $txOut))

# ===== Review dialog =====
function Show-ReviewDialog {
    $rv = Join-Path $Here 'review.json'
    if (-not (Test-Path $rv)) { [System.Windows.Forms.MessageBox]::Show('No review file yet. Run a scan first.', 'MailScrub'); return }
    $data = Get-Content $rv -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows = @($data.rows)
    if (-not $rows.Count) { [System.Windows.Forms.MessageBox]::Show('The last scan flagged nothing.', 'MailScrub'); return }
    $learned = @()
    $stFile = Join-Path $Here 'state.json'
    if (Test-Path $stFile) { $learned = @((Get-Content $stFile -Raw -Encoding UTF8 | ConvertFrom-Json).learned_allow) }

    $dlg = New-Object System.Windows.Forms.Form
    $gen = "$($data.generated)"; if ($data.generated -is [datetime]) { $gen = $data.generated.ToString('yyyy-MM-dd HH:mm') } elseif ($gen.Length -gt 16) { $gen = $gen.Substring(0, 16).Replace('T', ' ') }
    $dlg.Text = "Review flagged senders - scan of $gen"
    $dlg.Size = '1100,680'; $dlg.MinimumSize = '800,480'; $dlg.StartPosition = 'CenterParent'

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Checked = junk: the sender gets a marketing-only BLOCK rule (list headers or unsubscribe wording required, so receipts and support replies from it still arrive). Unchecked = KEEP: the sender is allowed ahead of every other filter. Double-click a row for sample subjects.'
    $hint.Location = '10,10'; $hint.Size = '1060,36'; $hint.Anchor = $A_TLR
    $dlg.Controls.Add($hint)

    $lbFilter = New-Object System.Windows.Forms.Label; $lbFilter.Text = 'Filter:'; $lbFilter.Location = '10,52'; $lbFilter.Size = '45,20'
    $txFilter = New-Object System.Windows.Forms.TextBox; $txFilter.Location = '58,50'; $txFilter.Size = '260,23'
    $btnAll = New-Button 'Check all' 330 48 90; $btnNone = New-Button 'Uncheck all' 426 48 100
    $lbCount = New-Object System.Windows.Forms.Label; $lbCount.Location = '540,52'; $lbCount.Size = '500,20'; $lbCount.Anchor = $A_TLR
    $dlg.Controls.AddRange(@($lbFilter, $txFilter, $btnAll, $btnNone, $lbCount))

    $g = New-Object System.Windows.Forms.DataGridView
    $g.Location = '10,80'; $g.Size = '1064,500'; $g.Anchor = $A_ALL
    $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false; $g.RowHeadersVisible = $false
    $g.SelectionMode = 'FullRowSelect'; $g.MultiSelect = $true; $g.AutoSizeColumnsMode = 'Fill'
    $g.AllowUserToResizeRows = $false; $g.EditMode = 'EditOnEnter'
    $cJunk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $cJunk.Name = 'junk'; $cJunk.HeaderText = 'Junk'; $cJunk.FillWeight = 12
    $cFrom = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $cFrom.Name = 'from'; $cFrom.HeaderText = 'Sender'; $cFrom.ReadOnly = $true; $cFrom.FillWeight = 60
    $cDom  = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $cDom.Name = 'domain'; $cDom.HeaderText = 'Domain'; $cDom.ReadOnly = $true; $cDom.FillWeight = 40
    $cN    = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $cN.Name = 'count'; $cN.HeaderText = 'Msgs'; $cN.ReadOnly = $true; $cN.FillWeight = 12
    $cN.ValueType = [int]; $cN.DefaultCellStyle.Alignment = 'MiddleRight'
    $cV    = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $cV.Name = 'verdict'; $cV.HeaderText = 'Verdict'; $cV.ReadOnly = $true; $cV.FillWeight = 18
    $cW    = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $cW.Name = 'why'; $cW.HeaderText = 'Reason'; $cW.ReadOnly = $true; $cW.FillWeight = 40
    $cS    = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $cS.Name = 'subject'; $cS.HeaderText = 'Sample subject'; $cS.ReadOnly = $true; $cS.FillWeight = 80
    foreach ($col in @($cJunk, $cFrom, $cDom, $cN, $cV, $cW, $cS)) { [void]$g.Columns.Add($col) }
    foreach ($r in $rows) {
        $checked = -not ($learned -contains $r.from)
        $subj = if ($r.subjects) { [string]$r.subjects[0] } else { '' }
        $why = [string]$r.why -replace '^heuristic:', ''
        $i = $g.Rows.Add($checked, $r.from, $r.domain, [int]$r.count, $r.verdict, $why, $subj)
        $g.Rows[$i].Tag = ($r.subjects -join "`r`n")
        if ($r.verdict -eq 'delete') { $g.Rows[$i].DefaultCellStyle.ForeColor = 'DarkRed' }
    }
    $dlg.Controls.Add($g)

    $btnSave = New-Button 'Save and create rules' 10 596 170 $A_BL
    $btnSave.Font = New-Object System.Drawing.Font($btnSave.Font, [System.Drawing.FontStyle]::Bold)
    $btnCancel = New-Button 'Cancel' 190 596 90 $A_BL
    $lbNote = New-Object System.Windows.Forms.Label
    $lbNote.Text = 'Red rows were flagged by the language filter. Unchecking one keeps that sender despite the language filter.'
    $lbNote.Location = '300,600'; $lbNote.Size = '770,20'; $lbNote.Anchor = $A_BLR
    $dlg.Controls.AddRange(@($btnSave, $btnCancel, $lbNote))

    $updateCount = {
        $junk = 0; $keep = 0
        foreach ($row in $g.Rows) { if ($row.Visible) { if ($row.Cells['junk'].Value -eq $true) { $junk++ } else { $keep++ } } }
        $lbCount.Text = "$($rows.Count) senders flagged   |   $junk marked junk, $keep to keep"
    }
    & $updateCount
    $g.Add_CurrentCellDirtyStateChanged({ if ($g.IsCurrentCellDirty) { $g.CommitEdit('Commit') } })
    $g.Add_CellValueChanged({ & $updateCount })
    $g.Add_CellDoubleClick({ param($s, $e) if ($e.RowIndex -ge 0) { [System.Windows.Forms.MessageBox]::Show($g.Rows[$e.RowIndex].Tag, $g.Rows[$e.RowIndex].Cells['from'].Value) } })
    $g.Add_KeyDown({ param($s, $e)
        if ($e.KeyCode -eq 'Space') {
            foreach ($row in $g.SelectedRows) { $row.Cells['junk'].Value = -not ($row.Cells['junk'].Value -eq $true) }
            $e.Handled = $true; & $updateCount
        }
    })
    $txFilter.Add_TextChanged({
        $f = $txFilter.Text.Trim()
        $g.CurrentCell = $null
        foreach ($row in $g.Rows) {
            $row.Visible = (-not $f) -or ("$($row.Cells['from'].Value) $($row.Cells['subject'].Value) $($row.Cells['why'].Value)" -like "*$f*")
        }
        & $updateCount
    })
    $btnAll.Add_Click({ foreach ($row in $g.Rows) { if ($row.Visible) { $row.Cells['junk'].Value = $true } }; & $updateCount })
    $btnNone.Add_Click({ foreach ($row in $g.Rows) { if ($row.Visible) { $row.Cells['junk'].Value = $false } }; & $updateCount })
    $btnCancel.Add_Click({ $dlg.Close() })
    $btnSave.Add_Click({
        $g.EndEdit()
        $allow = @(); $block = @()
        foreach ($row in $g.Rows) {
            if ($row.Cells['junk'].Value -eq $true) { $block += [string]$row.Cells['from'].Value } else { $allow += [string]$row.Cells['from'].Value }
        }
        $r = Invoke-EngineJson 'review-apply' @{ allow = $allow; block = $block }
        if ($r.Code -ne 0) { [System.Windows.Forms.MessageBox]::Show("Review failed:`n$($r.Out)$($r.Err)", 'MailScrub'); return }
        $txOut.AppendText("`r`n=== Review  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===`r`n$($r.Out)`r`n")
        Set-Status $r.Out.Trim()
        $dlg.Close()
        Load-All
    })
    [void]$dlg.ShowDialog($form)
}

# ===== Docs =====
$tDocs = New-Tab 'Docs'
$rtf = New-Object System.Windows.Forms.RichTextBox
$rtf.Location = '8,8'; $rtf.Size = '836,520'; $rtf.Anchor = $A_ALL; $rtf.ReadOnly = $true
$rtf.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$rtf.Text = @'
MAILSCRUB - HOW IT WORKS

Every scan reads the source folder over IMAP and decides one of four things for each message:
  KEEP        leave it alone
  ALLOW       leave it alone and stop evaluating (explicit trust)
  QUARANTINE  move to the Quarantine folder for review
  DELETE      move to the Trash folder (or delete permanently if no Trash folder exists)

ORDER OF EVALUATION (first match wins)
  1. Learned allow list (senders you rescued from Quarantine or unchecked in Review)
  2. Language filter       -> DELETE if confidently not in an allowed language
  3. ALLOW rules           -> ALLOW
  4. BLOCK rules           -> QUARANTINE
  5. Heuristics score      -> QUARANTINE if score reaches the threshold
  6. otherwise KEEP

ALLOW RULES - keeping receipts from companies that also send promos
  from:    regex matched against the sender address, e.g.  amazon\.com$
  subject: regex matched against the subject
  When both are present, both must match. So
      from = amazon\.com$   subject = order|shipped|receipt|invoice
  keeps order mail while Amazon marketing still goes to Quarantine.
  not_bulk: tick it to allow only when the message carries no list headers.
  A from of  .*  with a subject pattern makes a global allow for that subject.

BLOCK RULES
  Same two fields, plus:
  bulk_only: fire only when the message has list headers or unsubscribe wording. Rules created
             by Review are always bulk_only, so a support reply or shipping notice from a
             blocked address still reaches you while its marketing does not.
  note:      free text for your own reference ("review" marks rules Review created).

HEURISTICS - catching lists you have never seen
  Each signal adds its weight; reaching the threshold quarantines the message.
  "Unsubscribe wording in body" defaults to a weight that quarantines on its own, matching the
  rule of thumb that mail with an unsubscribe link is junk. Receipts that carry unsubscribe
  footers are rescued by the ALLOW rules, which run first.

LANGUAGE
  Subject and body go through an offline detector plus a non-Latin-script check. Mail confidently
  outside the allowed list gets the chosen action. "delete" moves to Trash when a Trash folder
  exists. This runs before ALLOW rules but after learned allows, so unchecking a red row in
  Review keeps that sender even if it writes in another language.

UNSUBSCRIBE
  Only RFC 8058 one-click is used: a POST to the https address in the List-Unsubscribe header
  when a List-Unsubscribe-Post header is present. Legitimate senders honour it. Links inside the
  message body are never followed, because in a list-bombing attack they confirm your address
  is live or lead to hostile pages. One attempt per sender; results are kept in state.json.

REVIEW FLAGGED (Run tab)
  After any scan, "Review flagged..." lists every sender the scan acted on, with message count,
  verdict, reason and a sample subject (double-click for more). Every box starts CHECKED = junk.
  Uncheck the senders you want to keep, then Save.
    checked   -> a bulk_only BLOCK rule for that exact address
    unchecked -> the address joins the learned allow list
  Type in the Filter box to narrow the list; Space toggles all selected rows.

REVIEW LOOP
  - Open the Quarantine folder in webmail. Drag anything legitimate back to the source folder.
    The next scan sees it and adds that sender to the learned allow list automatically.
  - "New-sender digest" lists domains first seen since the last digest.
  - Quarantine is emptied of mail older than the retention period by "Purge quarantine",
    which the daily task runs at 03:00.

DRY RUN
  While ticked, every action is logged with a DRY prefix and nothing is moved, deleted,
  or unsubscribed. Leave it on until a dry scan report looks right.

SAVING
  Rules, Filters and Settings tabs edit the same file, rules.yaml. Scan, Purge and Install ask
  before running if you have unsaved edits. Only one scan runs at a time: the GUI and the
  scheduled task share a lock, so "SKIPPED" in the console means the task was already scanning.

SCHEDULED TASKS
  "MailScrub Scan" runs a scan at the chosen interval and "MailScrub Purge" runs the purge daily,
  under your account, whether or not this window is open. They run the Python engine directly.
  The panel on the Settings tab shows the live task state; the interval box is only the value
  Install will use.

FILES (all in this folder)
  rules.yaml         all configuration above, editable by hand; missing keys take engine defaults
  credentials.json   IMAP host, port, user, and the DPAPI-encrypted password
  state.json         learned allows, keep cache, seen domains, unsubscribe history (state.json.bak = previous)
  scrub.log          every decision with its reason; rotates at 2 MB, five backups kept
  review.json        what the last scan flagged, for the Review dialog
  survey.json        raw header dump from the last Survey
  CLAUDE.md          developer documentation
'@
$tDocs.Controls.Add($rtf)

# ---------- load / save ----------
$script:savedJson = $null     # Collect-Config as JSON at last load/save, for unsaved-change detection
function Load-All {
    Set-Status 'Loading configuration...'
    try { $c = Get-Config } catch { [System.Windows.Forms.MessageBox]::Show("$_", 'MailScrub'); Set-Status 'Configuration failed to load'; return }
    $cr = (Invoke-Engine @('cred-get')).Out | ConvertFrom-Json
    $txHost.Text = $cr.host; $txUser.Text = $cr.user; $nuPort.Value = [int]$cr.port; $txPass.Text = ''
    $lbPassState.Text = if ($cr.error) { "Credentials: $($cr.error)" }
                        elseif (-not $cr.has_password) { 'No password stored yet.' }
                        elseif ($cr.encrypted) { 'A password is stored (DPAPI-encrypted).' }
                        else { 'A PLAINTEXT password is stored from an older version. Save credentials to encrypt it.' }
    $gAllow.Rows.Clear(); foreach ($r in @($c.allow)) { [void]$gAllow.Rows.Add($r.from, $r.subject, [bool]$r.not_bulk) }
    $gBlock.Rows.Clear(); foreach ($r in @($c.block)) { [void]$gBlock.Rows.Add($r.from, $r.subject, [bool]$r.bulk_only, $r.note) }
    $h = $c.heuristics
    $ckHEnabled.Checked = [bool]$h.enabled
    $ckListUnsub.Checked = [bool]$h.quarantine_if_list_unsubscribe; $nuWListUnsub.Value = [int]$h.weight_list_unsubscribe
    $ckPrecBulk.Checked = [bool]$h.quarantine_if_precedence_bulk;   $nuWPrec.Value = [int]$h.weight_precedence
    $nuWListId.Value = [int]$h.weight_list_id
    $ckSubConf.Checked = [bool]$h.quarantine_if_subscription_confirm; $nuWSubConf.Value = [int]$h.weight_subscription_confirm
    $ckUnsubLink.Checked = [bool]$h.quarantine_if_unsubscribe_link;   $nuUnsubW.Value = [int]$h.unsubscribe_link_weight
    $nuMin.Value = [int]$h.min_score
    $l = $c.language
    $ckLang.Checked = [bool]$l.enabled; $txLangs.Text = (@($l.allowed) -join ',')
    $nuConf.Value = [decimal]$l.min_confidence; $cbLangAct.SelectedItem = [string]$l.action
    $ckUnsub.Checked = [bool]$c.unsubscribe.enabled
    $s = $c.settings
    $txSrc.Text = $s.source_folder; $txQF.Text = $s.quarantine_folder; $txTr.Text = $s.trash_folder
    $ckTrash.Checked = [bool]$s.delete_to_trash; $nuRet.Value = [int]$s.quarantine_retention_days
    $ckLearn.Checked = [bool]$s.learn_from_restores; $ckDry.Checked = [bool]$s.dry_run; $ckRescan.Checked = [bool]$s.rescan_all
    $nuEvery.Value = [int]$s.scan_every_minutes
    $script:savedJson = (Collect-Config | ConvertTo-Json -Depth 6 -Compress)
    Update-TaskState
    Set-Status 'Configuration loaded'
}
function Grid-Rows($g, [string[]]$cols) {
    $rows = @()
    foreach ($row in $g.Rows) {
        if ($row.IsNewRow) { continue }
        $o = [ordered]@{}
        foreach ($c in $cols) {
            $v = $row.Cells[$c].Value
            if ($c -in $CheckColumns) { if ($v -eq $true) { $o[$c] = $true } }
            elseif ($v -and "$v".Trim()) { $o[$c] = "$v".Trim() }
        }
        if ($o.Count) { $rows += [pscustomobject]$o }
    }
    return $rows
}
function Collect-Config {
    [ordered]@{
        allow = @(Grid-Rows $gAllow @('from', 'subject', 'not_bulk'))
        block = @(Grid-Rows $gBlock @('from', 'subject', 'bulk_only', 'note'))
        heuristics = [ordered]@{
            enabled = $ckHEnabled.Checked
            quarantine_if_list_unsubscribe = $ckListUnsub.Checked
            quarantine_if_precedence_bulk = $ckPrecBulk.Checked
            quarantine_if_subscription_confirm = $ckSubConf.Checked
            quarantine_if_unsubscribe_link = $ckUnsubLink.Checked
            weight_list_unsubscribe = [int]$nuWListUnsub.Value
            weight_precedence = [int]$nuWPrec.Value
            weight_list_id = [int]$nuWListId.Value
            weight_subscription_confirm = [int]$nuWSubConf.Value
            unsubscribe_link_weight = [int]$nuUnsubW.Value
            min_score = [int]$nuMin.Value
        }
        language = [ordered]@{
            enabled = $ckLang.Checked
            allowed = @(($txLangs.Text -split '[,\s]+') | Where-Object { $_ })
            min_confidence = [double]$nuConf.Value
            action = "$($cbLangAct.SelectedItem)"
        }
        unsubscribe = [ordered]@{ enabled = $ckUnsub.Checked }
        settings = [ordered]@{
            source_folder = $txSrc.Text.Trim()
            quarantine_folder = $txQF.Text.Trim()
            trash_folder = $txTr.Text.Trim()
            delete_to_trash = $ckTrash.Checked
            quarantine_retention_days = [int]$nuRet.Value
            learn_from_restores = $ckLearn.Checked
            dry_run = $ckDry.Checked
            rescan_all = $ckRescan.Checked
            scan_every_minutes = [int]$nuEvery.Value
        }
    }
}
function Test-Dirty { ((Collect-Config | ConvertTo-Json -Depth 6 -Compress) -ne $script:savedJson) }
function Save-All {
    Set-Status 'Saving...'
    $cfg = Collect-Config
    $r = Invoke-EngineJson 'config-set' $cfg
    if ($r.Code -ne 0) { [System.Windows.Forms.MessageBox]::Show("Save failed:`n$($r.Out)$($r.Err)", 'MailScrub'); Set-Status 'Save failed'; return $false }
    $script:savedJson = ($cfg | ConvertTo-Json -Depth 6 -Compress)
    Set-Status 'Saved rules.yaml'
    return $true
}
function Confirm-SavedBeforeRun {
    # Returns $true when it is OK to run. Never saves silently.
    if (-not (Test-Dirty)) { return $true }
    $ans = [System.Windows.Forms.MessageBox]::Show('You have unsaved changes on the Rules, Filters or Settings tabs. Save them before running?', 'MailScrub', 'YesNoCancel', 'Question')
    if ($ans -eq 'Cancel') { return $false }
    if ($ans -eq 'Yes') { return (Save-All) }
    return $true    # No: run with the saved file, keep the edits in the window
}
function Save-Creds {
    $r = Invoke-EngineJson 'cred-set' ([ordered]@{ host = $txHost.Text.Trim(); port = [int]$nuPort.Value; user = $txUser.Text.Trim(); pass = $txPass.Text })
    if ($r.Code -ne 0) { [System.Windows.Forms.MessageBox]::Show("Credentials not saved:`n$($r.Out)$($r.Err)", 'MailScrub'); Set-Status 'Credentials not saved'; return $false }
    $aclNote = ''
    try {
        $acl = Get-Acl $CredFile; $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')))
        Set-Acl $CredFile $acl
        $aclNote = 'file ACL restricted to your account'
    } catch { $aclNote = "file ACL NOT changed ($($_.Exception.Message))" }
    $txPass.Text = ''
    $lbPassState.Text = 'A password is stored (DPAPI-encrypted).'
    Set-Status "Credentials saved, password encrypted; $aclNote"
    return $true
}

# ---------- background runner ----------
# Engine output goes to a temp file that a UI timer streams into the console, so the window
# stays responsive during long scans. Only one engine run at a time from the GUI.
$script:runProc = $null; $script:runOutFile = $null; $script:runPos = 0; $script:runLabel = ''
$script:runButtons = @()
$runTimer = New-Object System.Windows.Forms.Timer; $runTimer.Interval = $PumpIntervalMs
function Pump-Output {
    if (-not $script:runOutFile -or -not (Test-Path $script:runOutFile)) { return }
    try {
        $fs = [System.IO.File]::Open($script:runOutFile, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -gt $script:runPos) {
                $fs.Seek($script:runPos, 'Begin') | Out-Null
                $buf = New-Object byte[] ($fs.Length - $script:runPos)
                $n = $fs.Read($buf, 0, $buf.Length); $script:runPos += $n
                $txt = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n) -replace "(?<!`r)`n", "`r`n"
                $txOut.AppendText($txt); $txOut.SelectionStart = $txOut.TextLength; $txOut.ScrollToCaret()
            }
        } finally { $fs.Close() }
    } catch [System.IO.IOException] { <# the engine still holds the file open for a moment; the next tick retries #> }
}
$runTimer.Add_Tick({
    Pump-Output
    if ($script:runProc -and $script:runProc.HasExited) {
        $runTimer.Stop(); Pump-Output
        $code = $script:runProc.ExitCode
        $outcome = switch ($code) { 0 { 'finished' } 2 { 'FAILED (configuration)' } 3 { 'SKIPPED (another scan is running)' } default { "exited with code $code" } }
        $form.Cursor = 'Default'; Set-Status "$($script:runLabel) $outcome"
        foreach ($b in $script:runButtons) { $b.Enabled = $true }
        Remove-Item $script:runOutFile -ErrorAction SilentlyContinue
        $script:runProc = $null; $script:runOutFile = $null
    }
})
function Run-Engine([string[]]$cmd, [string]$label) {
    if ($script:runProc -and -not $script:runProc.HasExited) { Set-Status 'An engine run is already in progress'; return }
    Set-Status "Running $label..."; $form.Cursor = 'AppStarting'
    $tabs.SelectedTab = $tRun
    $txOut.AppendText("`r`n=== $label  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===`r`n")
    $script:runOutFile = Join-Path $env:TEMP ("mailscrub_run_{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $script:runPos = 0; $script:runLabel = $label
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = ('/c ""{0}" -X utf8 -u "{1}" {2} > "{3}" 2>&1"' -f $Python, $Engine, ($cmd -join ' '), $script:runOutFile)
    $psi.WorkingDirectory = $Here; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $script:runProc = [System.Diagnostics.Process]::Start($psi)
    foreach ($b in $script:runButtons) { $b.Enabled = $false }
    $runTimer.Start()
}

# ---------- scheduled tasks ----------
function Update-TaskState {
    $lines = foreach ($n in @($TaskScan, $TaskPurge)) {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        if ($t) {
            $i = Get-ScheduledTaskInfo -TaskName $n
            $last = if ($i.LastRunTime.Year -gt 2000) { "last $($i.LastRunTime.ToString('MM-dd HH:mm')) result $($i.LastTaskResult)" } else { 'never run' }
            "$n : $($t.State); $last; next $($i.NextRunTime.ToString('MM-dd HH:mm'))"
        } else { "$n : not installed" }
    }
    $lbTaskState.Text = ($lines -join "`r`n")
}
function Install-Tasks {
    $mins = [int]$nuEvery.Value
    $act1 = New-ScheduledTaskAction -Execute $Python -Argument "-X utf8 `"$Engine`" scan" -WorkingDirectory $Here
    $trg1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $mins)
    $act2 = New-ScheduledTaskAction -Execute $Python -Argument "-X utf8 `"$Engine`" purge-quarantine" -WorkingDirectory $Here
    $trg2 = New-ScheduledTaskTrigger -Daily -At $PurgeTime
    $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable -MultipleInstances IgnoreNew
    $t1 = Register-ScheduledTask -TaskName $TaskScan -Action $act1 -Trigger $trg1 -Settings $set -Force
    $t2 = Register-ScheduledTask -TaskName $TaskPurge -Action $act2 -Trigger $trg2 -Settings $set -Force
    if (-not $t1 -or -not $t2) { throw 'Task Scheduler did not return the registered task' }
    Update-TaskState; Set-Status "Scheduled tasks installed: scan every $mins min, purge daily at $PurgeTime"
}
function Remove-Tasks {
    foreach ($n in @($TaskScan, $TaskPurge)) { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
    Update-TaskState; Set-Status 'Scheduled tasks removed'
}

# ---------- wire up ----------
$btnTest.Add_Click({ if (Save-Creds) { Run-Engine @('test-connection') 'Test connection' } })
$btnSaveConn.Add_Click({ [void](Save-Creds) })
$btnRulesSave.Add_Click({ [void](Save-All) }); $btnFiltSave.Add_Click({ [void](Save-All) }); $btnSetSave.Add_Click({ [void](Save-All) })
$btnRulesReload.Add_Click({ Load-All })
$btnSurvey.Add_Click({ if (Confirm-SavedBeforeRun) { Run-Engine @('survey') 'Survey' } })
$btnScan.Add_Click({
    if (-not (Confirm-SavedBeforeRun)) { return }
    if (-not $ckDry.Checked) {
        $ans = [System.Windows.Forms.MessageBox]::Show('Dry run is OFF. This scan will move mail to Quarantine and Trash. Continue?', 'MailScrub', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
    }
    Run-Engine @('scan') 'Scan'
})
$btnDigest.Add_Click({ Run-Engine @('digest') 'Digest' })
$btnReview.Add_Click({ Show-ReviewDialog })
$btnPurge.Add_Click({ if (Confirm-SavedBeforeRun) { Run-Engine @('purge-quarantine') 'Purge quarantine' } })
$btnLog.Add_Click({ if (Test-Path $LogFile) { $txOut.Text = (Get-Content $LogFile -Tail $LogTailLines -Encoding UTF8) -join "`r`n"; $txOut.SelectionStart = $txOut.TextLength; $txOut.ScrollToCaret() } })
$btnClear.Add_Click({ $txOut.Clear() })
$btnTaskInstall.Add_Click({ if (Confirm-SavedBeforeRun) { try { Install-Tasks } catch { [System.Windows.Forms.MessageBox]::Show("Task install failed:`n$_", 'MailScrub') } } })
$btnTaskRemove.Add_Click({ Remove-Tasks })
$form.Add_FormClosing({ param($s, $e)
    if (Test-Dirty) {
        $ans = [System.Windows.Forms.MessageBox]::Show('Save your unsaved changes before closing?', 'MailScrub', 'YesNoCancel', 'Question')
        if ($ans -eq 'Cancel') { $e.Cancel = $true } elseif ($ans -eq 'Yes') { if (-not (Save-All)) { $e.Cancel = $true } }
    }
})
$script:runButtons = @($btnSurvey, $btnScan, $btnDigest, $btnPurge, $btnTest, $btnTaskInstall)
$form.Add_Shown({ Load-All })

[void]$form.ShowDialog()
