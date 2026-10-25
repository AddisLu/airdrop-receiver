# Generates the two generic iPhone shortcuts (no address or token inside).
# sign-shortcut.ps1 runs this, then signs them.
#
# 傳到電腦.plist — server URL asked for once at import.
#   Shared from any app  -> each item: web link? send as link : send as file
#   Run on its own        -> menu: 從電腦接收檔案 / 拿電腦的剪貼簿 / 把剪貼簿傳到電腦 /
#                                  選照片傳到電腦 / 選檔案傳到電腦
# 從電腦接收.plist — started by the ntfy push with "<address>/?ticket=…" as its input;
#   downloads everything waiting, no questions asked.
# All requests go to one URL with "&action=…" appended (see server.ps1).
$ErrorActionPreference = 'Stop'
$Ver = (Get-Content (Join-Path $PSScriptRoot '..\VERSION') -Raw).Trim()
$script:Sc = 'main'   # which shortcut is being built; sent as &sc=… with &sv=$Ver on every request

# --- plist building blocks ------------------------------------------------------
function Id([string]$name) {   # stable UUID per name, so rebuilds diff cleanly
    $h = [Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("airdrop-receiver/$name"))
    ([guid]::new($h)).ToString().ToUpper()
}
function Out([string]$uuidName, [string]$outName) { [ordered]@{ OutputName = $outName; OutputUUID = (Id $uuidName); Type = 'ActionOutput' } }
function VarRef([string]$name, [string]$coerce) {
    $v = [ordered]@{ Type = 'Variable'; VariableName = $name }
    if ($coerce) { $v.Aggrandizements = @(, [ordered]@{ CoercionItemClass = $coerce; Type = 'WFCoercionVariableAggrandizement' }) }
    $v
}
$ShortcutInput = [ordered]@{ Type = 'ExtensionInput' }
function Attach($att) { [ordered]@{ Value = $att; WFSerializationType = 'WFTextTokenAttachment' } }
function Tokens($att, [string]$suffix = '') {
    [ordered]@{ Value = [ordered]@{ attachmentsByRange = [ordered]@{ '{0, 1}' = $att }; string = "￼$suffix" }; WFSerializationType = 'WFTextTokenString' }
}
function Plain([string]$s) { [ordered]@{ Value = [ordered]@{ string = $s }; WFSerializationType = 'WFTextTokenString' } }
function Action([string]$id, $params = [ordered]@{}) { [ordered]@{ WFWorkflowActionIdentifier = "is.workflow.actions.$id"; WFWorkflowActionParameters = $params } }
function P([string]$uuidName, $params) { $o = [ordered]@{ UUID = (Id $uuidName) }; foreach ($k in $params.Keys) { $o[$k] = $params[$k] }; $o }
function Flow([string]$id, [string]$group, [int]$mode, $extra = [ordered]@{}) {
    $o = [ordered]@{ GroupingIdentifier = (Id $group); WFControlFlowMode = $mode }
    foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }
    Action $id $o
}
function TextField([string]$key, $att) { [ordered]@{ WFItemType = 0; WFKey = (Plain $key); WFValue = (Tokens $att) } }
function FileField([string]$key, $att) {
    [ordered]@{ WFItemType = 5; WFKey = (Plain $key); WFValue = [ordered]@{ Value = (Attach $att); WFSerializationType = 'WFTokenAttachmentParameterState' } }
}
$ServerUrl = Out 'url' '上傳網址'
# Get Contents of URL: <base><suffix>, GET, or POST with a form.
function Request([string]$uuidName, [string]$suffix, $fields, $requestVar, $base = $ServerUrl) {
    $p = [ordered]@{ WFURL = (Tokens $base "$suffix&sc=$($script:Sc)&sv=$Ver") }
    if ($fields) {
        $p.WFHTTPMethod = 'POST'
        $p.WFHTTPBodyType = 'Form'
        $p.ShowHeaders = $false
        $p.WFFormValues = [ordered]@{ Value = [ordered]@{ WFDictionaryFieldValueItems = @($fields) }; WFSerializationType = 'WFDictionaryFieldValue' }
        if ($requestVar) { $p.WFRequestVariable = (Attach $requestVar) }
    } else {
        $p.WFHTTPMethod = 'GET'
    }
    Action 'downloadurl' (P $uuidName $p)
}
function DictValue([string]$uuidName, [string]$key, $from) {
    Action 'getvalueforkey' (P $uuidName ([ordered]@{ WFDictionaryKey = $key; WFGetDictionaryValueType = 'Value'; WFInput = (Attach $from) }))
}
function Notify([string]$uuidName, $body) {
    Action 'notification' (P $uuidName ([ordered]@{ WFNotificationActionTitle = '傳到電腦'; WFNotificationActionBody = $body; WFNotificationActionSound = $false }))
}
function SetVar([string]$name, $from) { Action 'setvariable' ([ordered]@{ WFVariableName = $name; WFInput = (Attach $from) }) }

# List the PC outbox, then two loops — the server pre-splits the list, so there is no "If":
# iOS drops the comparison text of an If on a dictionary value ("請選擇此動作中每個參數的值").
#   media -> Photos;  files -> Files › iCloud Drive › Shortcuts, no questions.
# Each item is confirmed (its "done" URL) only after it saved; a failed save stops the
# shortcut and the item is fetched again next time.
function Receive-Loop([string]$key, [string]$saveId, $saveParams) {
    (DictValue "$key-items" $key (Out 'outbox-list' '網頁內容'))
    (Flow 'repeat.each' "$key-loop" 0 ([ordered]@{ WFInput = (Attach (Out "$key-items" '字典值')) }))
    (DictValue "$key-url" 'url' (VarRef 'Repeat Item'))
    (Action 'downloadurl' (P "$key-file" ([ordered]@{ WFURL = (Tokens (Out "$key-url" '字典值')); WFHTTPMethod = 'GET' })))
    $saveParams.WFInput = (Attach (Out "$key-file" '網頁內容'))
    (Action $saveId (P "$key-save" $saveParams))
    (DictValue "$key-done" 'done' (VarRef 'Repeat Item'))
    (Action 'downloadurl' (P "$key-ack" ([ordered]@{ WFURL = (Tokens (Out "$key-done" '字典值')); WFHTTPMethod = 'GET' })))
    (Flow 'repeat.each' "$key-loop" 2)
}

function Receive-Actions($base) {
    (Request 'outbox-list' '&action=outbox' $null $null $base)
    (Receive-Loop 'media' 'savetocameraroll' ([ordered]@{}))
    (Receive-Loop 'files' 'documentpicker.save' ([ordered]@{ WFAskWhereToSave = $false; WFSaveFileOverwrite = $false }))
    (DictValue 'outbox-message' 'message' (Out 'outbox-list' '網頁內容'))
    (Notify 'outbox-notify' (Tokens (Out 'outbox-message' '字典值')))
}

$Menu = '從電腦接收檔案', '拿電腦的剪貼簿', '把剪貼簿傳到電腦', '選照片傳到電腦', '選檔案傳到電腦'

# --- the shortcut ------------------------------------------------------------------
$actions = @(
    # 0: server URL, filled in by the import question
    (Action 'gettext' (P 'url' ([ordered]@{ CustomOutputName = '上傳網址'; WFTextActionText = '' })))

    # Shared from an app -> those items; run on its own -> menu
    (Flow 'conditional' 'has-input' 0 ([ordered]@{ WFCondition = 100; WFInput = [ordered]@{ Type = 'Variable'; Variable = (Attach $ShortcutInput) } }))
    (SetVar '項目' $ShortcutInput)
    (Flow 'conditional' 'has-input' 1)
    (Flow 'choosefrommenu' 'menu' 0 ([ordered]@{ WFMenuPrompt = "傳到電腦 v$Ver"; WFMenuItems = $Menu }))

    # --- 從電腦接收檔案: list the PC outbox, download each, save (media -> Photos)
    (Flow 'choosefrommenu' 'menu' 1 ([ordered]@{ WFMenuItemTitle = $Menu[0] }))
    (Receive-Actions $ServerUrl)
    (Action 'exit')

    # --- 拿電腦的剪貼簿: PC clipboard (text or image) -> iPhone clipboard
    (Flow 'choosefrommenu' 'menu' 1 ([ordered]@{ WFMenuItemTitle = $Menu[1] }))
    (Request 'pc-clip' '&action=clipboard')
    (Action 'setclipboard' (P 'set-clip' ([ordered]@{ WFInput = (Attach (Out 'pc-clip' '網頁內容')) })))
    (Notify 'pc-clip-notify' (Plain '已拿到電腦的剪貼簿，可以直接貼上'))
    (Action 'exit')

    # --- 把剪貼簿傳到電腦: "clip" carries images, "cliptext" plain text
    (Flow 'choosefrommenu' 'menu' 1 ([ordered]@{ WFMenuItemTitle = $Menu[2] }))
    (Action 'getclipboard' (P 'phone-clip' ([ordered]@{})))
    (Request 'send-clip' '&action=clip' @((FileField 'clip' (Out 'phone-clip' '剪貼簿')), (TextField 'cliptext' (Out 'phone-clip' '剪貼簿'))))
    (Notify 'send-clip-notify' (Plain '已傳到電腦的剪貼簿'))
    (Action 'exit')

    # --- 選照片 / 選檔案: pick, then fall through to the upload loop below
    (Flow 'choosefrommenu' 'menu' 1 ([ordered]@{ WFMenuItemTitle = $Menu[3] }))
    (Action 'selectphoto' (P 'pick-photos' ([ordered]@{ WFSelectMultiplePhotos = $true })))
    (SetVar '項目' (Out 'pick-photos' '照片'))
    (Flow 'choosefrommenu' 'menu' 1 ([ordered]@{ WFMenuItemTitle = $Menu[4] }))
    (Action 'documentpicker.open' (P 'pick-files' ([ordered]@{ WFShowFilePicker = $true; SelectMultiple = $true })))
    (SetVar '項目' (Out 'pick-files' '檔案'))
    (Flow 'choosefrommenu' 'menu' 2)
    (Flow 'conditional' 'has-input' 2)

    # --- upload each item. Web links (Safari pages, URLs, "share link") go as a link the PC
    # opens; everything else as a file. Decided by content: "as URL" starts with http only
    # for web links (files coerce to file:// URLs).
    (Flow 'repeat.each' 'upload-loop' 0 ([ordered]@{ WFInput = (Attach (VarRef '項目')) }))
    (Flow 'conditional' 'is-link' 0 ([ordered]@{ WFCondition = 8; WFConditionalActionString = 'http'
        WFInput = [ordered]@{ Type = 'Variable'; Variable = (Attach (VarRef 'Repeat Item' 'WFURLContentItem')) } }))
    (Request 'send-link' '' @(, (TextField 'url' (VarRef 'Repeat Item' 'WFURLContentItem'))))
    (Flow 'conditional' 'is-link' 1)
    (Request 'send-file' '' @(, (FileField 'file' (VarRef 'Repeat Item'))) (VarRef 'Repeat Item'))
    (Flow 'conditional' 'is-link' 2)
    (Flow 'repeat.each' 'upload-loop' 2)
    (Notify 'upload-notify' (Plain '已傳送完成'))
)

$workflow = [ordered]@{
    WFWorkflowActions = $actions
    WFWorkflowClientVersion = '2700.0.4'
    WFWorkflowHasOutputFallback = $false
    WFWorkflowHasShortcutInputVariables = $true
    WFWorkflowIcon = [ordered]@{ WFWorkflowIconGlyphNumber = 61440; WFWorkflowIconStartColor = 431817727 }
    WFWorkflowImportQuestions = @(, [ordered]@{
        ActionIndex = 0; Category = 'Parameter'; DefaultValue = ''; ParameterKey = 'WFTextActionText'
        Text = '貼上「傳到電腦」網頁剛複製的上傳網址' })
    # Safari web page is accepted as itself: otherwise iOS turns the page into rich text,
    # which means downloading it (blocked by Shortcuts privacy). No "Article" for the same reason.
    WFWorkflowInputContentItemClasses = @('WFGenericFileContentItem', 'WFImageContentItem', 'WFAVAssetContentItem',
        'WFPDFContentItem', 'WFSafariWebPageContentItem', 'WFStringContentItem', 'WFURLContentItem',
        'WFContactContentItem', 'WFFolderContentItem')
    WFWorkflowMinimumClientVersion = 900
    WFWorkflowMinimumClientVersionString = '900'
    WFWorkflowName = '傳到電腦'
    WFWorkflowOutputContentItemClasses = @()
    WFWorkflowTypes = @('ActionExtension')
}

# --- serialize ---------------------------------------------------------------------
function Esc([string]$s) { [Security.SecurityElement]::Escape($s) }
function Write-Plist($v, [int]$depth, [Text.StringBuilder]$sb) {
    $pad = "`t" * $depth
    if ($v -is [Collections.IDictionary]) {
        [void]$sb.AppendLine("$pad<dict>")
        foreach ($k in $v.Keys) {
            [void]$sb.AppendLine("$pad`t<key>$(Esc $k)</key>")
            Write-Plist $v[$k] ($depth + 1) $sb
        }
        [void]$sb.AppendLine("$pad</dict>")
    } elseif ($v -is [bool]) {
        [void]$sb.AppendLine("$pad<$("$v".ToLower())/>")
    } elseif ($v -is [int]) {
        [void]$sb.AppendLine("$pad<integer>$v</integer>")
    } elseif ($v -is [string]) {
        [void]$sb.AppendLine("$pad<string>$(Esc $v)</string>")
    } elseif ($v -is [Collections.IEnumerable]) {
        $items = @($v)
        if ($items.Count -eq 0) { [void]$sb.AppendLine("$pad<array/>"); return }
        [void]$sb.AppendLine("$pad<array>")
        foreach ($i in $items) { Write-Plist $i ($depth + 1) $sb }
        [void]$sb.AppendLine("$pad</array>")
    } else {
        throw "Unsupported plist value: $($v.GetType())"
    }
}

function Save-Plist($wf) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">')
    [void]$sb.AppendLine('<!-- Generated by build-shortcut.ps1; edit that script, not this file. -->')
    [void]$sb.AppendLine('<plist version="1.0">')
    Write-Plist $wf 0 $sb
    [void]$sb.AppendLine('</plist>')
    $out = Join-Path $PSScriptRoot "$($wf.WFWorkflowName).plist"
    [IO.File]::WriteAllText($out, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
    Write-Host "Wrote $out ($(@($wf.WFWorkflowActions).Count) actions)"
}

Save-Plist $workflow

# --- 從電腦接收: one tap on the ntfy push -------------------------------------------
# The push opens shortcuts://run-shortcut?name=從電腦接收&input=text&text=<address>/?ticket=…
# so this shortcut needs no setup at all. The name must stay exactly 從電腦接收.
$ReceiveBase = VarRef '伺服器'
$script:Sc = 'recv'
$receive = [ordered]@{
    WFWorkflowActions = @(
        (Flow 'conditional' 'has-ticket' 0 ([ordered]@{ WFCondition = 100; WFInput = [ordered]@{ Type = 'Variable'; Variable = (Attach $ShortcutInput) } }))
        (SetVar '伺服器' $ShortcutInput)
        (Flow 'conditional' 'has-ticket' 1)
        (Notify 'no-ticket' (Plain "從電腦接收 v$Ver：請從 ntfy 的「電腦傳來檔案」通知點開；手動接收請用「傳到電腦」捷徑的選單"))
        (Action 'exit')
        (Flow 'conditional' 'has-ticket' 2)
        (Receive-Actions $ReceiveBase)
    )
    WFWorkflowClientVersion = '2700.0.4'
    WFWorkflowHasOutputFallback = $false
    WFWorkflowHasShortcutInputVariables = $true
    WFWorkflowIcon = [ordered]@{ WFWorkflowIconGlyphNumber = 61440; WFWorkflowIconStartColor = 431817727 }
    WFWorkflowImportQuestions = @()
    WFWorkflowInputContentItemClasses = @('WFStringContentItem', 'WFURLContentItem')
    WFWorkflowMinimumClientVersion = 900
    WFWorkflowMinimumClientVersionString = '900'
    WFWorkflowName = '從電腦接收'
    WFWorkflowOutputContentItemClasses = @()
    WFWorkflowTypes = @()
}
Save-Plist $receive
