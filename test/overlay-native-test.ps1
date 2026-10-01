$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../native/desktop-overlay.ps1'))
$start=$source.IndexOf("using System;",$source.IndexOf('Add-Type -ReferencedAssemblies'))
$end=$source.IndexOf("'@",$start)
# Compile our renderer/hook class without launching a UI or installing a hook.
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Web.Extensions,System,System.Core -TypeDefinition $source.Substring($start,$end-$start)
$values=@([DesktopOverlay]::IsPhysicalEscape(27,0,0x100),[DesktopOverlay]::IsPhysicalEscape(27,0x20,0x104),[DesktopOverlay]::IsPhysicalEscape(27,0x10,0x100),[DesktopOverlay]::IsPhysicalEscape(27,0x2,0x100),[DesktopOverlay]::IsPhysicalEscape(27,0,0x101),[DesktopOverlay]::IsPhysicalEscape(65,0,0x100))
ConvertTo-Json -InputObject $values -Compress
