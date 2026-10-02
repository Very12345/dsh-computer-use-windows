# Controlled clipboard smoke: mock the key sender, use the real Windows
# clipboard, and restore the original formats. Never sends input to an app.
param()
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;using System.Threading;using System.Windows.Forms;using System.Runtime.InteropServices;
public class WindowsComputerUseNative {
 public struct POINT{public int x,y;}
 [DllImport("user32.dll",EntryPoint="GetClipboardSequenceNumber")]static extern uint ClipSequence();
 public static uint GetClipboardSequenceNumber(){if(Conflict&&++SequenceReads==2)Clipboard.SetText(External);return ClipSequence();}
 public static bool GetCursorPos(ref POINT p){return true;}
 public static string Value="",External="";public static int PasteCount=0,SequenceReads=0;public static bool Conflict=false;
 public static ManualResetEvent Done=new ManualResetEvent(false);
 public static bool SendKeyChord(string[] keys){if(keys[1].ToLower()!="v")return true;PasteCount++;Done.Reset();var t=new Thread(()=>{Thread.Sleep(700);try{Value=Clipboard.GetText(TextDataFormat.UnicodeText);}finally{Done.Set();}});t.SetApartmentState(ApartmentState.STA);t.Start();return true;}
}
"@
function Move-ToPoint {param([int]$X,[int]$Y)}
function Assert-VisualFocus {param($Target)}
function Assert-TargetIsForeground {param($Target)}
function Test-Failsafe {return $false}
function Get-Prop {param($Object,[string]$Name,$Default);if($Object.ContainsKey($Name)){return $Object[$Name]};return $Default}
function Get-ValueText {param($Element);return [WindowsComputerUseNative]::Value}
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../native/windows-uia.ps1'),[Text.Encoding]::UTF8)
$start=$source.IndexOf('function Type-Text {');$end=$source.IndexOf([char]10+'function Convert-KeyChord',$start)
Invoke-Expression ($source.Substring($start,$end-$start))
# Regression baseline: the previous 250ms restore and live OLE proxy.
function Old-Type-Text {
  param([string]$Text, [bool]$RestoreClipboard = $true, [object]$VisualTarget = $null)
  $position = New-Object WindowsComputerUseNative+POINT
  if (-not [WindowsComputerUseNative]::GetCursorPos([ref]$position)) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: Windows input desktop is unavailable.' }
  Move-ToPoint -X $position.x -Y $position.y
  $hadText = $false
  $oldText = $null
  try {
    $oldData = [System.Windows.Forms.Clipboard]::GetDataObject()
    $hadText = [System.Windows.Forms.Clipboard]::ContainsText()
    if ($hadText) { $oldText = [System.Windows.Forms.Clipboard]::GetText() }
  } catch {
    $hadText = $false
  }

  try {
    [System.Windows.Forms.Clipboard]::SetText($Text)
    Start-Sleep -Milliseconds 50
    if ($null -ne $VisualTarget) { Assert-VisualFocus $VisualTarget }
    if (-not [WindowsComputerUseNative]::SendKeyChord(@('Ctrl','v'))) { throw 'COMPUTER_USE_INPUT_UNAVAILABLE: paste input was rejected; effects may already exist.' }
    Start-Sleep -Milliseconds 250
  } finally { if ($RestoreClipboard) {
    try {
      if ($null -ne $oldData) {
        [System.Windows.Forms.Clipboard]::SetDataObject($oldData, $true)
      } elseif ($hadText) {
        [System.Windows.Forms.Clipboard]::SetText($oldText)
      } else {
        [System.Windows.Forms.Clipboard]::Clear()
      }
    } catch { }
  } }
}

$nonce='DSH-clipboard-fixture-'+[guid]::NewGuid().ToString('N')
$previous=$null;$priorKnown=$false
try{$d=[Windows.Forms.Clipboard]::GetDataObject();if($null-ne$d){$previous=New-Object Windows.Forms.DataObject;foreach($f in $d.GetFormats($false)){$v=$d.GetData($f,$false);if($null-ne$v){$previous.SetData($f,$false,$v)}}};$priorKnown=$true}catch{}
if(-not$priorKnown){throw 'Cannot snapshot the existing clipboard; fixture did not write anything.'}
$ownedMarker=$nonce+'-prior';$payload=$nonce+'-payload-'+[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('5Lit5paH8J+Zgg0K'));$external=$nonce+'-other-copy';$results=@();$ownedEmptySequence=0
try{
 [Windows.Forms.Clipboard]::SetText($ownedMarker)
 [WindowsComputerUseNative]::Value=''
 Old-Type-Text -Text $payload -VisualTarget @{}
 $ownedEmptySequence=[WindowsComputerUseNative]::GetClipboardSequenceNumber()
 if(-not[WindowsComputerUseNative]::Done.WaitOne(3000)){throw 'Old-reader timeout'}
 if([WindowsComputerUseNative]::Value-eq$payload){throw 'Old path did not reproduce the early-restore race'}
 if([WindowsComputerUseNative]::Value-ne''-and[WindowsComputerUseNative]::Value-ne$ownedMarker){throw 'Clipboard changed externally during the fixture'}
 $results+=@{case='old_delayed_reader';wrong_prior_clipboard=$true;empty=[WindowsComputerUseNative]::Value-eq'';paste_calls=[WindowsComputerUseNative]::PasteCount}
 [Windows.Forms.Clipboard]::SetText($ownedMarker);[WindowsComputerUseNative]::Value='';[WindowsComputerUseNative]::PasteCount=0
 $visual=Type-Text -Text $payload -VisualTarget @{}
 if(-not[WindowsComputerUseNative]::Done.WaitOne(3000)){throw 'Visual-reader timeout'}
 if([WindowsComputerUseNative]::Value-ne$payload-or-not$visual.write_verified-or-not$visual.retained-or$visual.restored){throw 'New visual path did not preserve asynchronous data'}
 if([WindowsComputerUseNative]::PasteCount-ne1){throw 'Input was replayed'}
 $results+=@{case='visual_delayed_reader';write_verified=$visual.write_verified;retained=$visual.retained;paste_calls=1}
 [Windows.Forms.Clipboard]::SetText($ownedMarker);[WindowsComputerUseNative]::Value='';[WindowsComputerUseNative]::PasteCount=0
 $edit=[pscustomobject]@{Current=[pscustomobject]@{HasKeyboardFocus=$true;IsPassword=$false}}
 $uia=Type-Text -Text $payload -Editable $edit -InputTarget @{}
 if([WindowsComputerUseNative]::Value-ne$payload-or-not$uia.write_verified-or-not$uia.restored-or$uia.retained){throw 'UIA path did not wait for readback and restore the prior clipboard'}
 if([Windows.Forms.Clipboard]::GetText()-ne$ownedMarker){throw 'Prior clipboard not restored'}
 $results+=@{case='uia_delayed_reader';write_verified=$true;restored=$true;paste_calls=[WindowsComputerUseNative]::PasteCount}
 [Windows.Forms.Clipboard]::SetText($ownedMarker);[WindowsComputerUseNative]::Value='prefix-'+$payload;[WindowsComputerUseNative]::PasteCount=0
 $replacement=Type-Text -Text $payload -Editable $edit -InputTarget @{} -Replace $true
 if([WindowsComputerUseNative]::Value-ne$payload-or-not$replacement.target_text_observed-or-not$replacement.restored-or[WindowsComputerUseNative]::PasteCount-ne1){throw 'Replacement did not use a single paste and confirm the exact target value'}
 $results+=@{case='uia_replacement';target_text_observed=$true;restored=$true;paste_calls=1}
 [Windows.Forms.Clipboard]::SetText($ownedMarker);[WindowsComputerUseNative]::PasteCount=0;[WindowsComputerUseNative]::External=$external;[WindowsComputerUseNative]::SequenceReads=0;[WindowsComputerUseNative]::Conflict=$true
 $rejected=$false;try{Type-Text -Text $payload -VisualTarget @{}|Out-Null}catch{if($_.Exception.Message-notmatch'^CLIPBOARD_CHANGED:.*No text sent'){throw};$rejected=$true}finally{[WindowsComputerUseNative]::Conflict=$false}
 if(-not$rejected-or[WindowsComputerUseNative]::PasteCount-ne0-or[Windows.Forms.Clipboard]::GetText()-ne$external){throw 'Concurrent copy was overwritten or input dispatched'}
 $results+=@{case='concurrent_copy';rejected_before_input=$true;paste_calls=0;other_copy_preserved=$true}
 $results|ConvertTo-Json -Compress
}finally{
 # Never replace a real user's copy made during the fixture.
 $current=[Windows.Forms.Clipboard]::GetText()
 if($current.StartsWith($nonce,[StringComparison]::Ordinal)-or($current-eq''-and[WindowsComputerUseNative]::GetClipboardSequenceNumber()-eq$ownedEmptySequence)){
  if($null-ne$previous){[Windows.Forms.Clipboard]::SetDataObject($previous,$true)}else{[Windows.Forms.Clipboard]::Clear()}
 }
}
