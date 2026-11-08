# MailScrubGui.ps1 - WinForms front end for mailscrub.py
# Run:  pwsh -NoProfile -File MailScrubGui.ps1   (Windows PowerShell 5.1 also works)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Engine   = Join-Path $Here 'mailscrub.py'
$CredFile = Join-Path $Here 'credentials.json'
$LogFile  = Join-Path $Here 'scrub.log'
$Python   = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $Python) { [System.Windows.Forms.MessageBox]::Show('python.exe not found on PATH'); exit 1 }

# ---------- engine bridge ----------
function Invoke-Engine {
    param([string[]]$EngineArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Python
    $psi.Arguments = ('-X utf8 "{0}" {1}' -f $Engine, ($EngineArgs -join ' '))
    $psi.WorkingDirectory = $Here
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $err }
}
function Get-Config { (Invoke-Engine @('config-get')).Out | ConvertFrom-Json }
function Set-Config($cfg) {
    $tmp = Join-Path $env:TEMP 'mailscrub_rules.json'
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
    Invoke-Engine @('config-set', ('"{0}"' -f $tmp))
}

# ---------- helpers ----------
$A_TL  = [System.Windows.Forms.AnchorStyles]'Top,Left'
$A_TLR = [System.Windows.Forms.AnchorStyles]'Top,Left,Right'
$A_ALL = [System.Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
$A_BL  = [System.Windows.Forms.AnchorStyles]'Bottom,Left'
$A_BR  = [System.Windows.Forms.AnchorStyles]'Bottom,Right'

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
function New-Num($x, $y, $min, $max, $dec = 0) {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Location = "$x,$y"; $n.Size = "80,23"; $n.Minimum = $min; $n.Maximum = $max
    $n.DecimalPlaces = $dec; $n.Increment = $(if ($dec) { 0.05 } else { 1 }); $n.Anchor = $A_TL; $n
}
function New-Button($text, $x, $y, $w = 120, $anchor = $A_TL) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = "$x,$y"; $b.Size = "$w,28"; $b.Anchor = $anchor; $b
}
function New-Grid($x, $y, $w, $h, [string[]]$cols) {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Location = "$x,$y"; $g.Size = "$w,$h"; $g.Anchor = $A_ALL
    $g.AllowUserToAddRows = $true; $g.AllowUserToDeleteRows = $true
    $g.AutoSizeColumnsMode = 'Fill'; $g.RowHeadersVisible = $false
    foreach ($c in $cols) {
        if ($c -in @('not_bulk', 'bulk_only')) {
            $col = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
            $col.FillWeight = 25
        } else { $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn }
        $col.Name = $c; $col.HeaderText = $c; [void]$g.Columns.Add($col)
    }
    $g
}

# ---------- form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'MailScrub'; $form.Size = '900,640'; $form.MinimumSize = '760,520'
$form.StartPosition = 'CenterScreen'

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = '8,8'; $tabs.Size = '868,548'; $tabs.Anchor = $A_ALL
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
$btnTest = New-Button 'Test connection' 160 160 140
$btnSaveConn = New-Button 'Save credentials' 310 160 140
$lbConnNote = New-Label 'Credentials are stored in credentials.json in this folder, readable only by your Windows account. Use a password you can rotate.' 16 204 600
$lbConnNote.Size = '640,40'; $lbConnNote.Anchor = $A_TLR
$tConn.Controls.AddRange(@($btnTest, $btnSaveConn, $lbConnNote))

# ===== Rules =====
$tRules = New-Tab 'Rules'
$lbAllow = New-Label 'ALLOW rules (win over everything). from/subject are regexes; when both given, both must match. not_bulk = only if no list headers.' 8 8 820
$lbAllow.Size = '820,20'; $lbAllow.Anchor = $A_TLR
$gAllow = New-Grid 8 30 836 200 @('from', 'subject', 'not_bulk')
$lbBlock = New-Label 'BLOCK rules (quarantine on match). bulk_only = only when the message has list headers or unsubscribe wording, so support replies and shipping notices from that sender still get through.' 8 240 836
$gBlock = New-Grid 8 262 836 200 @('from', 'subject', 'bulk_only', 'note')
$gBlock.Anchor = [System.Windows.Forms.AnchorStyles]'Bottom,Left,Right'
$btnRulesSave = New-Button 'Save rules' 8 470 120 $A_BL
$btnRulesReload = New-Button 'Reload' 136 470 100 $A_BL
$tRules.Controls.AddRange(@($lbAllow, $gAllow, $lbBlock, $gBlock, $btnRulesSave, $btnRulesReload))

# ===== Filters =====
$tFilt = New-Tab 'Filters'
$gbH = New-Object System.Windows.Forms.GroupBox; $gbH.Text = 'Heuristics (new list mail you have never seen)'
$gbH.Location = '12,10'; $gbH.Size = '820,190'; $gbH.Anchor = $A_TLR
$ckHEnabled = New-Check 'Enable heuristics' 16 24
$ckListUnsub = New-Check 'List-Unsubscribe header present  (+1)' 16 48
$ckPrecBulk  = New-Check 'Precedence: bulk / list / junk  (+1)' 16 72
$ckSubConf   = New-Check '"Confirm your subscription" style subject  (+2)' 16 96
$ckUnsubLink = New-Check 'Unsubscribe / opt-out wording in body' 16 120 300
$nuUnsubW = New-Num 330 120 0 10; $lbUnsubW = New-Label 'weight' 416 122 60
$lbMin = New-Label 'Quarantine when score reaches' 16 152 200; $nuMin = New-Num 220 150 1 10
$gbH.Controls.AddRange(@($ckHEnabled, $ckListUnsub, $ckPrecBulk, $ckSubConf, $ckUnsubLink, $nuUnsubW, $lbUnsubW, $lbMin, $nuMin))

$gbL = New-Object System.Windows.Forms.GroupBox; $gbL.Text = 'Language'
$gbL.Location = '12,210'; $gbL.Size = '820,120'; $gbL.Anchor = $A_TLR
$ckLang = New-Check 'Enable language filter (checked before allow rules)' 16 24
$lbAllowed = New-Label 'Allowed languages (ISO codes, comma separated)' 16 52 280; $txLangs = New-Text 300 50 160 $A_TL
$lbConf = New-Label 'Minimum confidence' 16 84 160; $nuConf = New-Num 180 82 0.5 1 2
$lbAct = New-Label 'Action' 300 84 50
$cbLangAct = New-Object System.Windows.Forms.ComboBox; $cbLangAct.Location = '350,82'; $cbLangAct.Size = '120,23'
$cbLangAct.DropDownStyle = 'DropDownList'; [void]$cbLangAct.Items.AddRange(@('delete', 'quarantine'))
$gbL.Controls.AddRange(@($ckLang, $lbAllowed, $txLangs, $lbConf, $nuConf, $lbAct, $cbLangAct))

$gbU = New-Object System.Windows.Forms.GroupBox; $gbU.Text = 'Unsubscribe'
$gbU.Location = '12,340'; $gbU.Size = '820,70'; $gbU.Anchor = $A_TLR
$ckUnsub = New-Check 'Send RFC 8058 one-click unsubscribe for mail being removed (header-based only; body links are never clicked)' 16 24 780
$gbU.Controls.Add($ckUnsub)
$btnFiltSave = New-Button 'Save filters' 12 470 120 $A_BL
$tFilt.Controls.AddRange(@($gbH, $gbL, $gbU, $btnFiltSave))

# ===== Settings =====
$tSet = New-Tab 'Settings'
$lbQF = New-Label 'Quarantine folder' 16 24; $txQF = New-Text 180 22 240 $A_TL
$lbRet = New-Label 'Retention (days)' 16 56; $nuRet = New-Num 180 54 1 365
$ckLearn = New-Check 'Learn from restores: a message moved back from Quarantine to Inbox allow-lists its sender' 16 90 700
$ckDry = New-Check 'DRY RUN - report only, never move or delete mail' 16 116 500
$ckDry.ForeColor = 'DarkRed'
$ckRescan = New-Check 'Re-scan messages previously judged keep (slower; use after changing rules)' 16 142 600
$gbTask = New-Object System.Windows.Forms.GroupBox; $gbTask.Text = 'Windows Scheduled Task'
$gbTask.Location = '12,180'; $gbTask.Size = '820,110'; $gbTask.Anchor = $A_TLR
$lbEvery = New-Label 'Scan every (minutes)' 16 28 150; $nuEvery = New-Num 170 26 5 1440
$btnTaskInstall = New-Button 'Install / update task' 16 62 160
$btnTaskRemove = New-Button 'Remove task' 186 62 120
$lbTaskState = New-Label '' 320 66 480; $lbTaskState.Anchor = $A_TLR
$gbTask.Controls.AddRange(@($lbEvery, $nuEvery, $btnTaskInstall, $btnTaskRemove, $lbTaskState))
$btnSetSave = New-Button 'Save settings' 12 470 120 $A_BL
$tSet.Controls.AddRange(@($lbQF, $txQF, $lbRet, $nuRet, $ckLearn, $ckDry, $ckRescan, $gbTask, $btnSetSave))

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
$txOut.Location = '8,44'; $txOut.Size = '836,460'; $txOut.Anchor = $A_ALL
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
    $hint.Text = 'Checked = junk (sender will be BLOCKED).  Uncheck anything you want to KEEP (sender will be ALLOWED, ahead of all other filters).  Double-click a row to see sample subjects.'
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
    $lbNote.Text = 'Red rows were flagged for deletion (foreign language). Unchecking one keeps that sender despite the language filter.'
    $lbNote.Location = '300,600'; $lbNote.Size = '770,20'; $lbNote.Anchor = [System.Windows.Forms.AnchorStyles]'Bottom,Left,Right'
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
            $hit = (-not $f) -or ("$($row.Cells['from'].Value) $($row.Cells['subject'].Value) $($row.Cells['why'].Value)" -like "*$f*")
            $row.Visible = $hit
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
        $tmp = Join-Path $env:TEMP 'mailscrub_review.json'
        @{ allow = $allow; block = $block } | ConvertTo-Json | Set-Content $tmp -Encoding UTF8
        $r = Invoke-Engine @('review-apply', ('"{0}"' -f $tmp))
        if ($r.Code -ne 0) { [System.Windows.Forms.MessageBox]::Show("Failed:`n$($r.Err)$($r.Out)"); return }
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
$rtf.Location = '8,8'; $rtf.Size = '836,500'; $rtf.Anchor = $A_ALL; $rtf.ReadOnly = $true
$rtf.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$rtf.Text = @'
MAILSCRUB - HOW IT WORKS

Every scan reads the Inbox over IMAP and decides one of four things for each message:
  KEEP        leave it alone
  ALLOW       leave it alone and stop evaluating (explicit trust)
  QUARANTINE  move to the Quarantine folder for review
  DELETE      remove permanently (foreign-language mail only, by default)

ORDER OF EVALUATION
  1. Learned allow list (senders you rescued from Quarantine)
  2. Language filter       -> DELETE if not an allowed language
  3. ALLOW rules           -> ALLOW
  4. BLOCK rules           -> QUARANTINE
  5. Heuristics score      -> QUARANTINE if score >= threshold
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
  Same two fields. Any match sends the message to Quarantine.

HEURISTICS - catching lists you have never seen
  Each signal adds to a score. Reaching the threshold quarantines the message.
  The "unsubscribe wording in body" signal defaults to a weight that quarantines on its own,
  matching the rule of thumb that mail with an unsubscribe link is junk.
  Receipts that contain unsubscribe footers are rescued by the ALLOW rules, which run first.

LANGUAGE
  The subject and body are run through an offline detector plus a non-Latin-script check.
  Mail confidently outside the allowed list is deleted and logged. Choose quarantine instead
  if you want a review window. Note this runs before ALLOW rules, so a German receipt is removed.

UNSUBSCRIBE
  Only the RFC 8058 one-click mechanism is used: a POST to the https address in the
  List-Unsubscribe header when a List-Unsubscribe-Post header is present. Legitimate senders
  honour it. Links inside the message body are never followed, because in a list-bombing
  attack they confirm your address is live or lead to hostile pages. One attempt per sender.

REVIEW FLAGGED (Run tab)
  After any scan, "Review flagged..." opens a checklist of every sender the scan would quarantine
  or delete, with message count, verdict, reason and a sample subject (double-click for more).
  Every box starts CHECKED = junk. Uncheck the senders you want to keep, then Save.
    checked   -> an exact-address BLOCK rule is written to rules.yaml
    unchecked -> the address joins the learned allow list, which runs before every other check,
                 including the language filter (so an unchecked red row is kept even if foreign)
  Changing your mind later: run Review again after the next scan, or edit the Rules tab.
  Type in the Filter box to narrow the list; Space toggles all selected rows.

REVIEW LOOP
  - Open the Quarantine folder in webmail. Drag anything legitimate back to the Inbox.
    The next scan sees it and adds that sender to the learned allow list automatically.
  - "New-sender digest" lists domains first seen since the last digest, so you can
    promote them to ALLOW or BLOCK.
  - Quarantine is emptied of mail older than the retention period by "Purge quarantine".

DRY RUN
  While ticked, every action is logged with a DRY prefix and nothing is moved, deleted,
  or unsubscribed. Leave it on until a dry scan report looks right.

SCHEDULED TASK
  Installs a Windows task that runs a scan at the chosen interval and a purge once a day,
  under your account, whether or not this window is open. The task runs the Python engine
  directly, not this GUI.

FILES (all in this folder)
  rules.yaml         all configuration above, editable by hand
  credentials.json   IMAP host, user, password
  state.json         learned allows, seen domains, unsubscribe history
  scrub.log          every decision, with the reason
  survey.json        raw header dump from the last survey
'@
$tDocs.Controls.Add($rtf)

# ---------- load / save ----------
$script:cfg = $null
function Load-All {
    Set-Status 'Loading configuration...'
    $script:cfg = Get-Config
    $c = $script:cfg
    if (Test-Path $CredFile) {
        $cr = Get-Content $CredFile -Raw | ConvertFrom-Json
        $txHost.Text = $cr.host; $txUser.Text = $cr.user; $txPass.Text = $cr.pass
        $nuPort.Value = $(if ($cr.port) { $cr.port } else { 993 })
    } else { $nuPort.Value = 993 }
    $gAllow.Rows.Clear(); foreach ($r in @($c.allow)) { [void]$gAllow.Rows.Add($r.from, $r.subject, [bool]$r.not_bulk) }
    $gBlock.Rows.Clear(); foreach ($r in @($c.block)) { [void]$gBlock.Rows.Add($r.from, $r.subject, [bool]$r.bulk_only, $r.note) }
    $h = $c.heuristics
    $ckHEnabled.Checked = [bool]$h.enabled; $ckListUnsub.Checked = [bool]$h.quarantine_if_list_unsubscribe
    $ckPrecBulk.Checked = [bool]$h.quarantine_if_precedence_bulk; $ckSubConf.Checked = [bool]$h.quarantine_if_subscription_confirm
    $ckUnsubLink.Checked = [bool]$h.quarantine_if_unsubscribe_link
    $nuUnsubW.Value = $(if ($null -ne $h.unsubscribe_link_weight) { $h.unsubscribe_link_weight } else { 2 })
    $nuMin.Value = $(if ($h.min_score) { $h.min_score } else { 2 })
    $l = $c.language
    $ckLang.Checked = [bool]$l.enabled; $txLangs.Text = (@($l.allowed) -join ',')
    $nuConf.Value = [decimal]$(if ($l.min_confidence) { $l.min_confidence } else { 0.85 })
    $cbLangAct.SelectedItem = $(if ($l.action) { $l.action } else { 'delete' })
    $ckUnsub.Checked = [bool]$c.unsubscribe.enabled
    $s = $c.settings
    $txQF.Text = $s.quarantine_folder; $nuRet.Value = $s.quarantine_retention_days
    $ckLearn.Checked = [bool]$s.learn_from_restores; $ckDry.Checked = [bool]$s.dry_run; $ckRescan.Checked = [bool]$s.rescan_all
    $nuEvery.Value = $(if ($s.scan_every_minutes) { $s.scan_every_minutes } else { 15 })
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
            if ($c -in @('not_bulk', 'bulk_only')) { if ($v -eq $true) { $o[$c] = $true } }
            elseif ($v -and "$v".Trim()) { $o[$c] = "$v".Trim() }
        }
        if ($o.Count) { $rows += [pscustomobject]$o }
    }
    return $rows
}
function Collect-Config {
    $c = [ordered]@{
        allow = @(Grid-Rows $gAllow @('from', 'subject', 'not_bulk'))
        block = @(Grid-Rows $gBlock @('from', 'subject', 'bulk_only', 'note'))
        heuristics = [ordered]@{
            enabled = $ckHEnabled.Checked
            quarantine_if_list_unsubscribe = $ckListUnsub.Checked
            quarantine_if_precedence_bulk = $ckPrecBulk.Checked
            quarantine_if_subscription_confirm = $ckSubConf.Checked
            quarantine_if_unsubscribe_link = $ckUnsubLink.Checked
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
            quarantine_folder = $txQF.Text.Trim()
            quarantine_retention_days = [int]$nuRet.Value
            learn_from_restores = $ckLearn.Checked
            dry_run = $ckDry.Checked
            rescan_all = $ckRescan.Checked
            scan_every_minutes = [int]$nuEvery.Value
        }
    }
    return $c
}
function Save-All {
    Set-Status 'Saving...'
    $r = Set-Config (Collect-Config)
    if ($r.Code -ne 0) { [System.Windows.Forms.MessageBox]::Show("Save failed:`n$($r.Err)") ; Set-Status 'Save failed'; return }
    Set-Status 'Saved rules.yaml'
}
function Save-Creds {
    $o = [ordered]@{ host = $txHost.Text.Trim(); port = [int]$nuPort.Value; user = $txUser.Text.Trim(); pass = $txPass.Text }
    $o | ConvertTo-Json | Set-Content -Path $CredFile -Encoding UTF8
    try {
        $acl = Get-Acl $CredFile; $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')))
        Set-Acl $CredFile $acl
    } catch {}
    Set-Status 'Credentials saved (file restricted to your account)'
}
# Background runner: engine output is redirected to a temp file and streamed into the console
# by a UI timer, so the window stays responsive during long scans.
$script:runProc = $null; $script:runOutFile = $null; $script:runPos = 0; $script:runLabel = ''
$script:runButtons = @()
$runTimer = New-Object System.Windows.Forms.Timer; $runTimer.Interval = 400
function Pump-Output {
    if (-not $script:runOutFile -or -not (Test-Path $script:runOutFile)) { return }
    try {
        $fs = [System.IO.File]::Open($script:runOutFile, 'Open', 'Read', 'ReadWrite')
        if ($fs.Length -gt $script:runPos) {
            $fs.Seek($script:runPos, 'Begin') | Out-Null
            $buf = New-Object byte[] ($fs.Length - $script:runPos)
            $n = $fs.Read($buf, 0, $buf.Length); $script:runPos += $n
            $txt = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n) -replace "(?<!`r)`n", "`r`n"
            $txOut.AppendText($txt); $txOut.SelectionStart = $txOut.TextLength; $txOut.ScrollToCaret()
        }
        $fs.Close()
    } catch {}
}
$runTimer.Add_Tick({
    Pump-Output
    if ($script:runProc -and $script:runProc.HasExited) {
        $runTimer.Stop(); Start-Sleep -Milliseconds 150; Pump-Output
        $code = $script:runProc.ExitCode
        $form.Cursor = 'Default'; Set-Status "$($script:runLabel) finished (exit $code)"
        foreach ($b in $script:runButtons) { $b.Enabled = $true }
        $script:runProc = $null
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

# ---------- scheduled task ----------
$TaskScan = 'MailScrub Scan'; $TaskPurge = 'MailScrub Purge'
function Update-TaskState {
    $t = Get-ScheduledTask -TaskName $TaskScan -ErrorAction SilentlyContinue
    if ($t) {
        $i = Get-ScheduledTaskInfo -TaskName $TaskScan
        $lbTaskState.Text = "Installed. State: $($t.State). Last run: $($i.LastRunTime) (result $($i.LastTaskResult)). Next: $($i.NextRunTime)"
    } else { $lbTaskState.Text = 'Not installed.' }
}
function Install-Tasks {
    $pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    $mins = [int]$nuEvery.Value
    $act1 = New-ScheduledTaskAction -Execute $Python -Argument "-X utf8 `"$Engine`" scan" -WorkingDirectory $Here
    $trg1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $mins)
    $act2 = New-ScheduledTaskAction -Execute $Python -Argument "-X utf8 `"$Engine`" purge-quarantine" -WorkingDirectory $Here
    $trg2 = New-ScheduledTaskTrigger -Daily -At 3am
    $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -StartWhenAvailable -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskScan -Action $act1 -Trigger $trg1 -Settings $set -Force | Out-Null
    Register-ScheduledTask -TaskName $TaskPurge -Action $act2 -Trigger $trg2 -Settings $set -Force | Out-Null
    Update-TaskState; Set-Status "Scheduled task installed: scan every $mins min, purge daily 03:00"
}
function Remove-Tasks {
    foreach ($n in @($TaskScan, $TaskPurge)) { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
    Update-TaskState; Set-Status 'Scheduled tasks removed'
}

# ---------- wire up ----------
$btnTest.Add_Click({ Save-Creds; Run-Engine @('test-connection') 'Test connection' })
$btnSaveConn.Add_Click({ Save-Creds })
$btnRulesSave.Add_Click({ Save-All }); $btnFiltSave.Add_Click({ Save-All }); $btnSetSave.Add_Click({ Save-All })
$btnRulesReload.Add_Click({ Load-All })
$btnSurvey.Add_Click({ Run-Engine @('survey') 'Survey' })
$btnScan.Add_Click({
    Save-All
    if (-not $ckDry.Checked) {
        $ans = [System.Windows.Forms.MessageBox]::Show('Dry run is OFF. This scan will move and delete mail. Continue?', 'MailScrub', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
    }
    Run-Engine @('scan') 'Scan'
})
$btnDigest.Add_Click({ Run-Engine @('digest') 'Digest' })
$btnReview.Add_Click({ Show-ReviewDialog })
$btnPurge.Add_Click({ Save-All; Run-Engine @('purge-quarantine') 'Purge quarantine' })
$btnLog.Add_Click({ if (Test-Path $LogFile) { $txOut.Text = (Get-Content $LogFile -Tail 400) -join "`r`n"; $txOut.SelectionStart = $txOut.TextLength; $txOut.ScrollToCaret() } })
$btnClear.Add_Click({ $txOut.Clear() })
$btnTaskInstall.Add_Click({ Save-All; try { Install-Tasks } catch { [System.Windows.Forms.MessageBox]::Show("Task install failed:`n$_") } })
$btnTaskRemove.Add_Click({ Remove-Tasks })
$script:runButtons = @($btnSurvey, $btnScan, $btnDigest, $btnPurge, $btnTest, $btnTaskInstall)
$form.Add_Shown({ Load-All })

[void]$form.ShowDialog()

